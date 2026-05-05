import Foundation

struct NamespaceActivitySnapshot: Equatable {
    let instances: [NamespaceInstance]
    let error: String?
}

struct NamespaceInstanceDetailSnapshot: Equatable {
    let detail: NamespaceInstanceDetail?
    let error: String?
}

enum NamespaceActivityPoller {
    static func fetch() async -> NamespaceActivitySnapshot {
        guard let nsc = resolveNSC() else {
            return NamespaceActivitySnapshot(
                instances: [],
                error: "nsc not found on PATH candidates"
            )
        }
        let output = await runGHCapturing(
            executable: nsc,
            args: ["list", "--all", "-o", "json"],
            timeout: 12
        )
        return decode(rawOutput: output)
    }

    static func fetchDetail(instanceID: String) async -> NamespaceInstanceDetailSnapshot {
        guard let nsc = resolveNSC() else {
            return NamespaceInstanceDetailSnapshot(
                detail: nil,
                error: "nsc not found on PATH candidates"
            )
        }
        let output = await runGHCapturing(
            executable: nsc,
            args: ["describe", instanceID, "-o", "json"],
            timeout: 12
        )
        return decodeDetail(rawOutput: output)
    }

    static func decode(rawOutput: String) -> NamespaceActivitySnapshot {
        guard let json = extractJSONArray(from: rawOutput),
              let data = json.data(using: .utf8)
        else {
            return NamespaceActivitySnapshot(
                instances: [],
                error: "nsc returned no JSON; run nsc login if the session expired"
            )
        }
        do {
            let raw = try JSONDecoder().decode([RawInstance].self, from: data)
            return NamespaceActivitySnapshot(
                instances: raw.compactMap(\.instance),
                error: nil
            )
        } catch {
            return NamespaceActivitySnapshot(
                instances: [],
                error: "could not parse nsc list JSON"
            )
        }
    }

    static func decodeDetail(rawOutput: String) -> NamespaceInstanceDetailSnapshot {
        guard let json = extractJSONArray(from: rawOutput),
              let data = json.data(using: .utf8)
        else {
            return NamespaceInstanceDetailSnapshot(
                detail: NamespaceInstanceDetail(containers: []),
                error: nil
            )
        }
        do {
            let raw = try JSONDecoder().decode([RawDescribeResource].self, from: data)
            let containers = raw
                .flatMap(\.records)
                .flatMap(\.containers)
                .map(\.state)
            return NamespaceInstanceDetailSnapshot(
                detail: NamespaceInstanceDetail(containers: containers),
                error: nil
            )
        } catch {
            return NamespaceInstanceDetailSnapshot(
                detail: nil,
                error: "could not parse nsc describe JSON"
            )
        }
    }

    private static func extractJSONArray(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed
        }
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start <= end
        else { return nil }
        return String(raw[start...end])
    }

    private static func resolveNSC() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/nsc",
            "/usr/local/bin/nsc",
            "/usr/bin/nsc",
            home + "/.local/bin/nsc",
            home + "/.pulp/bin/nsc",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct RawInstance: Decodable {
        let clusterID: String
        let createdAt: String
        let ingressDomain: String?
        let labels: [String: String]?
        let shape: Shape

        var instance: NamespaceInstance? {
            guard let created = NamespaceDateParser.parse(createdAt) else { return nil }
            return NamespaceInstance(
                id: clusterID,
                repo: labels?["nsc.runner-repo"] ?? "",
                purpose: labels?["nsc.purpose"] ?? "",
                profileTag: labels?["nsc.runner-profile-tag"],
                os: shape.os,
                arch: shape.machineArch,
                virtualCPU: shape.virtualCPU,
                memoryMegabytes: shape.memoryMegabytes,
                createdAt: created,
                ingressDomain: ingressDomain
            )
        }

        enum CodingKeys: String, CodingKey {
            case clusterID = "cluster_id"
            case createdAt = "created_at"
            case ingressDomain = "ingress_domain"
            case labels
            case shape
        }
    }

    private struct RawDescribeResource: Decodable {
        let perResource: [String: RawDescribeRecord]?

        var records: [RawDescribeRecord] {
            guard let perResource else { return [] }
            return Array(perResource.values)
        }

        enum CodingKeys: String, CodingKey {
            case perResource = "per_resource"
        }
    }

    private struct RawDescribeRecord: Decodable {
        let containers: [RawContainer]

        enum CodingKeys: String, CodingKey {
            case containers = "container"
        }
    }

    private struct RawContainer: Decodable {
        let id: String
        let name: String
        let startedAt: String?
        let ready: Bool?
        let status: String?

        var state: NamespaceContainerState {
            NamespaceContainerState(
                id: id,
                name: name,
                status: status ?? "",
                ready: ready ?? false,
                startedAt: startedAt.flatMap(NamespaceDateParser.parse),
                updatedAt: nil
            )
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case startedAt = "started_at"
            case ready
            case status
        }
    }

    private enum NamespaceDateParser {
        static func parse(_ raw: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            if let normalized = normalizeFraction(raw),
               let date = fractional.date(from: normalized) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }

        private static func normalizeFraction(_ raw: String) -> String? {
            guard let dot = raw.firstIndex(of: ".") else { return nil }
            let fractionStart = raw.index(after: dot)
            guard let suffixStart = raw[fractionStart...].firstIndex(where: {
                $0 == "Z" || $0 == "+" || $0 == "-"
            }) else { return nil }
            let fraction = raw[fractionStart..<suffixStart]
            guard !fraction.isEmpty else { return nil }
            let trimmed = fraction.prefix(6)
            return String(raw[..<fractionStart] + trimmed + raw[suffixStart...])
        }
    }

    private struct Shape: Decodable {
        let virtualCPU: Int
        let memoryMegabytes: Int
        let machineArch: String
        let os: String

        enum CodingKeys: String, CodingKey {
            case virtualCPU = "virtual_cpu"
            case memoryMegabytes = "memory_megabytes"
            case machineArch = "machine_arch"
            case os
        }
    }
}
