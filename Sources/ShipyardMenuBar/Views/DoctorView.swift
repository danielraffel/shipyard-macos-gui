import SwiftUI

struct DoctorView: View {
    @EnvironmentObject var store: AppStore
    @State private var checking: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Doctor")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let last = store.lastDoctorCheckedAt {
                        Text("checked \(relative(last))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button(checking ? "Checking…" : "Re-check") {
                        Task { await runCheck() }
                    }
                    .disabled(checking || store.cliBinaryResolved == nil)
                }

                if store.cliBinaryResolved == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        MessageBox(
                            icon: "exclamationmark.triangle.fill",
                            tint: .orange,
                            title: "Shipyard CLI not found",
                            message: "This app is a companion — it needs the Shipyard CLI installed separately."
                        )
                        Link("Install instructions at github.com/danielraffel/Shipyard →",
                             destination: URL(string: "https://github.com/danielraffel/Shipyard#installation")!)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.leading, 8)
                    }
                }

                if let result = store.doctorResult {
                    ForEach(result.checks.sorted(by: { $0.key < $1.key }), id: \.key) { key, ok in
                        HStack {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ok ? .green : .red)
                            Text(key)
                                .font(.system(size: 12))
                            Spacer()
                        }
                    }
                }

                Text("Checks are machine-level. Per-repo probes run via `shipyard doctor` in each worktree.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
            .padding(16)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    @MainActor
    private func runCheck() async {
        guard let binary = store.cliBinaryResolved else { return }
        checking = true
        defer { checking = false }
        let out = await runShipyard(binary: binary, args: ["doctor", "--json"])
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            store.doctorResult = DoctorResult(ok: false, checks: [:], rawJSON: out)
            store.lastDoctorCheckedAt = Date()
            return
        }
        var flat: [String: Bool] = [:]
        if let checks = json["checks"] as? [String: [String: Any]] {
            for (section, items) in checks {
                for (name, payload) in items {
                    if let dict = payload as? [String: Any],
                       let ok = dict["ok"] as? Bool {
                        flat["\(section) · \(name)"] = ok
                    }
                }
            }
        }
        let ok = (json["ready"] as? Bool) ?? flat.values.allSatisfy { $0 }
        store.doctorResult = DoctorResult(ok: ok, checks: flat, rawJSON: out)
        store.lastDoctorCheckedAt = Date()
    }
}

private func runShipyard(binary: String, args: [String]) async -> String {
    await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                cont.resume(returning: "")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

struct MessageBox: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
