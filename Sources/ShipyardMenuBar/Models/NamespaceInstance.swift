import Foundation

struct NamespaceInstance: Identifiable, Equatable, Hashable {
    let id: String
    let repo: String
    let purpose: String
    let profileTag: String?
    let os: String
    let arch: String
    let virtualCPU: Int
    let memoryMegabytes: Int
    let createdAt: Date
    let ingressDomain: String?

    var platformKey: String? {
        NamespacePlatform.key(from: os)
    }

    var shortOS: String {
        switch os.lowercased() {
        case "windows": return "win"
        case "macos": return "mac"
        default: return os.lowercased()
        }
    }

    var shapeLabel: String {
        "\(platformLabel) \(sizeLabel)"
    }

    var platformLabel: String {
        "\(shortOS)/\(displayArch)"
    }

    var sizeLabel: String {
        let memoryGB = max(1, Int((Double(memoryMegabytes) / 1024.0).rounded()))
        return "\(virtualCPU)x\(memoryGB)"
    }

    var title: String {
        if purpose == "github-runner" {
            return "GitHub runner"
        }
        return purpose.isEmpty ? "Namespace instance" : purpose
    }

    private var displayArch: String {
        let lowerArch = arch.lowercased()
        if shortOS == "mac", lowerArch == "arm64" {
            return "silicon"
        }
        return lowerArch
    }
}

struct NamespaceInstanceDetail: Equatable {
    let containers: [NamespaceContainerState]

    var statusSummary: String {
        guard !containers.isEmpty else { return "No container state exposed" }
        return containers
            .map { "\($0.name): \($0.statusLabel)" }
            .joined(separator: ", ")
    }
}

struct NamespaceContainerState: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let status: String
    let ready: Bool
    let startedAt: Date?
    let updatedAt: Date?

    var statusLabel: String {
        let readiness = ready ? "ready" : "not ready"
        return "\(status.isEmpty ? "unknown" : status), \(readiness)"
    }
}

enum NamespacePlatform {
    static func key(from raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("windows") || lower == "win" { return "windows" }
        if lower.contains("linux") || lower.contains("ubuntu") { return "linux" }
        if lower.contains("macos") || lower == "mac" || lower.contains("mac/") { return "macos" }
        return nil
    }
}
