import Foundation

/// An append-only record of everything Dustloft has removed.
///
/// A cleaner asks you to trust it with irreversible operations, then shows you
/// the result once and throws it away. This is the receipt: what was touched,
/// when, how big it was, and whether it went to the Trash or was unlinked.
///
/// It never leaves the machine. Nothing here is sent anywhere, and the file is
/// plain text so it can be read, grepped or deleted without this app.
enum OperationLog {

    nonisolated static var url: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Dustloft", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("operations.log")
    }

    /// Tab-separated so `cut`, `grep` and `awk` all work on it directly.
    /// Paths are written in full: an audit trail that elides the path cannot
    /// answer the only question anyone asks it afterwards.
    nonisolated static func record(action: CleanAction, name: String,
                                   bytes: Int64, ok: Bool, message: String?) {
        let verb: String
        let path: String
        switch action {
        case .trashPath(let p):       verb = "trash";       path = p
        case .removePath(let p):      verb = "delete";      path = p
        case .removePathAdmin(let p): verb = "delete-admin"; path = p
        case .gitGC(let p):           verb = "git-gc";      path = p
        case .ollamaModel(let n):     verb = "ollama-rm";   path = n
        case .dockerPrune:            verb = "docker-prune"; path = "-"
        case .adminShell(let c):      verb = "admin-shell"; path = c
        case .advisory:               return   // never executed, never logged
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let status = ok ? "ok" : "failed"
        let note = message.map { "\t\($0)" } ?? ""
        let line = "\(stamp)\t\(verb)\t\(status)\t\(bytes)\t\(name)\t\(path)\(note)\n"

        guard let data = line.data(using: .utf8) else { return }
        let u = url
        if let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: u)
        }
    }
}
