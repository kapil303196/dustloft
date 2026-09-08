import Foundation

/// Thin, synchronous process wrapper. Always call off the main thread.
enum Shell {

    struct Result {
        let out: String
        let err: String
        let code: Int32
        var ok: Bool { code == 0 }
    }

    /// GUI apps inherit a minimal PATH, so tools must be resolved by hand.
    private static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        NSHomeDirectory() + "/.local/bin"
    ]

    static func which(_ tool: String) -> String? {
        for d in searchDirs {
            let p = d + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 180) -> Result {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Result(out: "", err: "not found: \(path)", code: 127)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        p.environment = env

        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e

        do { try p.run() } catch {
            return Result(out: "", err: error.localizedDescription, code: 126)
        }

        // Read concurrently so a full pipe buffer can't deadlock us.
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async {
            outData = (try? o.fileHandleForReading.readToEnd()) ?? Data(); g.leave()
        }
        g.enter(); DispatchQueue.global().async {
            errData = (try? e.fileHandleForReading.readToEnd()) ?? Data(); g.leave()
        }

        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchQueue.global()
        var timedOut = false
        watchdog.asyncAfter(deadline: deadline) {
            if p.isRunning { timedOut = true; p.terminate() }
        }
        p.waitUntilExit()
        g.wait()

        return Result(
            out: String(data: outData, encoding: .utf8) ?? "",
            err: timedOut ? "timed out" : (String(data: errData, encoding: .utf8) ?? ""),
            code: p.terminationStatus
        )
    }

    /// Convenience: run a tool found on PATH.
    static func tool(_ name: String, _ args: [String], timeout: TimeInterval = 180) -> Result {
        guard let p = which(name) else {
            return Result(out: "", err: "\(name) not installed", code: 127)
        }
        return run(p, args, timeout: timeout)
    }

    // MARK: Sizing

    /// Apparent disk usage in bytes. `-x` keeps us on one filesystem.
    static func diskUsage(_ path: String) -> Int64 {
        let r = run("/usr/bin/du", ["-skx", path], timeout: 600)
        guard let first = r.out.split(separator: "\n").first,
              let kb = Int64(first.split(separator: "\t").first?
                  .trimmingCharacters(in: .whitespaces) ?? "") else { return 0 }
        return kb * 1024
    }

    static func fileSize(_ path: String) -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return (a?[.size] as? Int64) ?? 0
    }

    // MARK: Privileged execution

    /// One authorisation prompt for the whole batch, via the native admin dialog.
    static func runAsAdmin(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: 900)
    }
}
