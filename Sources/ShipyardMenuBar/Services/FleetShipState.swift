import Foundation

/// A PR tracked by a *remote* fleet Mac's Shipyard, surfaced read-only so you
/// can see what M1 / Mac Studio are managing from any Mac. Sourced from each
/// host's local `shipyard --json ship-state list` over SSH/Tailscale — NO
/// GitHub API calls, so it never touches the rate-limit budget.
struct FleetPR: Identifiable, Equatable {
    let machine: String      // display name of the managing Mac (e.g. "M3")
    let repo: String
    let prNumber: Int
    let title: String
    let branch: String
    let prURL: String?
    /// Last-recorded CI status from the remote Mac's ship-state evidence
    /// (no GitHub call). May be stale, but reflects what that Mac knows.
    let status: Status
    /// Per-target last-known results from that Mac's ship-state — shown when the
    /// row is expanded. Quota-free (ship-state, not GitHub).
    let lanes: [Lane]

    enum Status: Equatable { case passed, failed, pending }

    struct Lane: Identifiable, Equatable {
        let target: String       // e.g. "mac", "linux", "windows"
        let result: Status
        let phase: String?       // e.g. "test", "build" (last phase seen)
        var id: String { target }
    }

    // Stable across refreshes: a PR is identified by machine + repo + number.
    var id: String { "\(machine)\t\(repo)\t\(prNumber)" }
}

/// A remote Mac to pull ship-state from. `ssh` is the ~/.ssh/config alias/target.
struct FleetHost: Decodable, Equatable {
    let name: String
    let ssh: String
}

enum FleetShipState {
    /// Remote fleet hosts (this Mac is always "This Mac" and read locally). Read
    /// from ~/.config/shipyard/fleet-hosts.json — `[{"name":"M3","ssh":"macstudio"}, …]`.
    /// Missing/garbage file ⇒ no remote hosts (feature simply shows only This Mac).
    static func hosts(path: String = defaultHostsPath()) -> [FleetHost] {
        guard let data = FileManager.default.contents(atPath: path),
              let hosts = try? JSONDecoder().decode([FleetHost].self, from: data)
        else { return [] }
        // Drop blanks/dupes; keep order. Reject a leading "-" so a config value
        // can't be parsed by ssh as an option (e.g. -oProxyCommand=…).
        var seen = Set<String>()
        return hosts.filter {
            !$0.name.isEmpty && !$0.ssh.isEmpty
                && !$0.ssh.hasPrefix("-") && !$0.name.hasPrefix("-")
                && seen.insert($0.ssh).inserted
        }
    }

    static func defaultHostsPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".config/shipyard/fleet-hosts.json")
    }

    /// Pull every remote host's ship-state concurrently over SSH. Each host has a
    /// hard timeout; an unreachable/slow Mac just drops out (returns no PRs for
    /// it) rather than blocking. Quota-free — runs each Mac's *local* shipyard.
    static func fetch(hosts: [FleetHost] = hosts(),
                      sshTimeoutSeconds: Int = 8) async -> [FleetPR] {
        await withTaskGroup(of: [FleetPR].self) { group in
            for host in hosts {
                group.addTask { await fetchOne(host: host, sshTimeoutSeconds: sshTimeoutSeconds) }
            }
            var all: [FleetPR] = []
            for await prs in group { all.append(contentsOf: prs) }
            return all.sorted { ($0.machine, $0.repo, $0.prNumber) < ($1.machine, $1.repo, $1.prNumber) }
        }
    }

    private static func fetchOne(host: FleetHost, sshTimeoutSeconds: Int) async -> [FleetPR] {
        // `ssh -o BatchMode=yes` never prompts (no agent in a Finder-launched GUI);
        // the user's passphraseless per-host key + IdentitiesOnly handle auth.
        let raw = await runCapturing(
            executable: "/usr/bin/ssh",
            args: [
                "-o", "ConnectTimeout=\(max(2, sshTimeoutSeconds - 2))",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                host.ssh,
                "$HOME/.local/bin/shipyard --json ship-state list",
            ],
            timeoutSeconds: sshTimeoutSeconds
        )
        guard let entries = ShipStateListEntry.decode(fromJSON: raw) else { return [] }
        return map(entries, machine: host.name)
    }

    /// Map decoded ship-state entries → fleet PRs, dropping entries with no repo.
    /// Internal for tests.
    static func map(_ entries: [ShipStateListEntry], machine: String) -> [FleetPR] {
        entries.compactMap { e in
            guard let repo = e.repo, !repo.isEmpty else { return nil }
            let lanes = self.lanes(evidence: e.evidenceSnapshot, runs: e.dispatchedRuns)
            return FleetPR(
                machine: machine,
                repo: repo,
                prNumber: e.pr,
                title: e.prTitle ?? e.commitSubject ?? "",
                branch: e.branch ?? "",
                prURL: e.prUrl,
                status: overall(of: lanes),
                lanes: lanes
            )
        }
    }

    /// Per-target last-known lanes from the ship-state. The evidence snapshot
    /// (`{target: "pass"|"fail"}`) is authoritative for pass/fail; dispatched_runs
    /// add the phase and any targets without evidence yet. All from ship-state —
    /// no GitHub call.
    static func lanes(evidence: [String: String]?,
                      runs: [WatchEvent.DispatchedRun]?) -> [FleetPR.Lane] {
        let ev = evidence ?? [:]
        var byTarget: [String: FleetPR.Lane] = [:]
        func result(target: String, runStatus: String?) -> FleetPR.Status {
            switch ev[target]?.lowercased() {
            case "fail": return .failed
            case "pass": return .passed
            default: break
            }
            switch runStatus?.lowercased() {
            case "failed": return .failed
            case "completed": return .passed   // completed + no fail evidence ⇒ best-effort pass
            default: return .pending            // cancelled / running / queued / none
            }
        }
        for r in runs ?? [] {
            byTarget[r.target] = FleetPR.Lane(target: r.target,
                                              result: result(target: r.target, runStatus: r.status),
                                              phase: r.phase)
        }
        for target in ev.keys where byTarget[target] == nil {
            byTarget[target] = FleetPR.Lane(target: target,
                                            result: result(target: target, runStatus: nil),
                                            phase: nil)
        }
        return byTarget.values.sorted { $0.target < $1.target }
    }

    /// Overall PR status = worst lane (any fail ⇒ failed, else any pass ⇒ passed).
    static func overall(of lanes: [FleetPR.Lane]) -> FleetPR.Status {
        if lanes.contains(where: { $0.result == .failed }) { return .failed }
        if lanes.contains(where: { $0.result == .passed }) { return .passed }
        return .pending
    }

    private static func runCapturing(
        executable: String, args: [String], timeoutSeconds: Int
    ) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            ShipyardProcessEnvironment.configure(process)   // sets HOME so ~/.ssh/config resolves
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice   // don't let stderr fill + block
            do { try process.run() } catch { cont.resume(returning: ""); return }
            // Hard deadline: a watchdog terminates the process, which closes the
            // pipe and unblocks the read below. This bounds the whole call even if
            // the remote `shipyard` hangs with stdout still open (ssh's own
            // ConnectTimeout only covers the connect phase).
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + .seconds(timeoutSeconds))
            watchdog.setEventHandler { if process.isRunning { process.terminate() } }
            watchdog.resume()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
