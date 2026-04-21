import Foundation

/// Bare-bones file-based trace for diagnosing the live-mode pipeline.
///
/// Only active in DEBUG builds. Appends timestamped lines to
/// `/tmp/shipyard-webhook.log` — `tail -f` it from a terminal while
/// the app runs. Release builds compile this to a no-op so nothing
/// from this path ships in the DMG.
enum DebugTrace {
    #if DEBUG
    private static let path = "/tmp/shipyard-webhook.log"
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(dateFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
    #else
    @inline(__always)
    static func log(_ message: String) {}
    #endif
}
