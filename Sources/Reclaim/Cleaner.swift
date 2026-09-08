import Foundation
import SwiftUI

struct CleanOutcome: Identifiable {
    let id = UUID()
    var name: String
    var bytes: Int64
    var ok: Bool
    var message: String?
}

@MainActor
final class Cleaner: ObservableObject {

    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var currentStep = ""
    @Published var outcomes: [CleanOutcome] = []
    @Published var freedBytes: Int64 = 0
    @Published var finished = false

    /// Executes the chosen items. Admin removals are collected and run under a
    /// single authorisation prompt rather than one dialog per path.
    func run(_ items: [ScanItem]) async {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        finished = false
        outcomes = []
        freedBytes = 0
        progress = 0

        let before = VolumeInfo.current().free

        let adminItems = items.filter { if case .removePathAdmin = $0.action { return true }; return false }
        let normal = items.filter { if case .removePathAdmin = $0.action { return false }; return true }

        let total = Double(normal.count + (adminItems.isEmpty ? 0 : 1))
        var done = 0.0

        for item in normal {
            currentStep = item.name
            let res: (Bool, String?) = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Cleaner.perform(item.action))
                }
            }
            outcomes.append(CleanOutcome(name: item.name, bytes: item.bytes,
                                         ok: res.0, message: res.1))
            if res.0 { freedBytes += item.bytes }
            done += 1
            progress = done / total
        }

        if !adminItems.isEmpty {
            currentStep = "Waiting for administrator authorisation…"
            let paths = adminItems.compactMap { item -> String? in
                if case .removePathAdmin(let p) = item.action { return p }
                return nil
            }
            let quoted = paths.map { "'\($0)'" }.joined(separator: " ")
            let res: Shell.Result = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Shell.runAsAdmin("/bin/rm -rf " + quoted))
                }
            }
            for item in adminItems {
                outcomes.append(CleanOutcome(
                    name: item.name, bytes: item.bytes, ok: res.ok,
                    message: res.ok ? nil : (res.err.isEmpty ? "authorisation cancelled" : res.err)))
                if res.ok { freedBytes += item.bytes }
            }
            done += 1
            progress = done / total
        }

        // Prefer the real delta from the filesystem over the sum of estimates.
        let after = VolumeInfo.current().free
        if after > before { freedBytes = after - before }

        currentStep = ""
        progress = 1
        isRunning = false
        finished = true
    }

    // MARK: - Action execution (background thread only)

    nonisolated private static func perform(_ action: CleanAction) -> (Bool, String?) {
        switch action {

        case .removePath(let p):
            guard !Settings.hardExclusions.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) else {
                return (false, "refused: protected location")
            }
            do {
                try FileManager.default.removeItem(atPath: p)
                return (true, nil)
            } catch {
                let r = Shell.run("/bin/rm", ["-rf", p], timeout: 900)
                return r.ok ? (true, nil) : (false, r.err.isEmpty ? "could not remove" : r.err)
            }

        case .removePathAdmin:
            return (false, "handled in the batched admin step")

        case .ollamaModel(let name):
            let r = Shell.tool("ollama", ["rm", name], timeout: 120)
            return r.ok ? (true, nil) : (false, r.err)

        case .dockerPrune:
            guard let docker = Shell.which("docker") else { return (false, "docker not found") }
            var startedByUs = false
            if !Shell.run(docker, ["info"], timeout: 20).ok {
                _ = Shell.run("/usr/bin/open", ["-a", "Docker"], timeout: 30)
                startedByUs = true
                var waited = 0
                while waited < 90, !Shell.run(docker, ["info"], timeout: 10).ok {
                    Thread.sleep(forTimeInterval: 3); waited += 3
                }
            }
            guard Shell.run(docker, ["info"], timeout: 15).ok else {
                return (false, "Docker daemon did not start")
            }
            // -a removes unused images and stopped containers. No --volumes, ever.
            let r = Shell.run(docker, ["system", "prune", "-a", "-f"], timeout: 900)
            if startedByUs {
                _ = Shell.run("/usr/bin/osascript", ["-e", "quit app \"Docker\""], timeout: 30)
            }
            return r.ok ? (true, nil) : (false, r.err)

        case .gitGC(let repo):
            guard let git = Shell.which("git") else { return (false, "git not found") }
            let r = Shell.run(git, ["-C", repo, "gc", "--prune=now"], timeout: 900)
            return r.ok ? (true, nil) : (false, r.err)

        case .advisory:
            return (false, "advisory only")
        }
    }
}
