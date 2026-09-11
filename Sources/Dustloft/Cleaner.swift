import Foundation
import SwiftUI

struct CleanOutcome: Identifiable {
    let id = UUID()
    /// The ScanItem this came from, so the UI can drop it once it is gone.
    var itemID: UUID
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
    /// Permanent-tier items go to the Trash instead of being unlinked, so they
    /// never show up in the volume delta. Reported separately or a person who
    /// cleaned 92 GB of media would be told they freed nothing.
    @Published var trashedBytes: Int64 = 0
    @Published var finished = false

    /// Ids of everything that was actually removed.
    var cleanedIDs: [UUID] { outcomes.filter { $0.ok }.map { $0.itemID } }

    /// What Dustloft itself removed — items sent to the Trash included, since
    /// the person asked for those to go and they leave when the Trash is
    /// emptied. Everything shown against this figure says "cleaned" rather than
    /// "freed" for that reason.
    ///
    /// Deliberately not `freedBytes`: that figure is overwritten by the volume
    /// delta, which is the right number to show someone staring at their disk
    /// but the wrong one to add up, because it also counts whatever else macOS
    /// happened to do during the run. It cannot be used as a ceiling here
    /// either — an APFS snapshot routinely holds deleted space for hours, so a
    /// real 50 GB removal can show a delta of nothing.
    var accountedBytes: Int64 { outcomes.filter { $0.ok }.reduce(0) { $0 + $1.bytes } }

    /// Executes the chosen items. Admin removals are collected and run under a
    /// single authorisation prompt rather than one dialog per path.
    func run(_ items: [ScanItem]) async {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        finished = false
        outcomes = []
        freedBytes = 0
        trashedBytes = 0
        progress = 0

        let before = VolumeInfo.current().free

        // Everything needing elevation is gathered so macOS asks for the
        // password once, not once per item.
        let adminItems = items.filter {
            switch $0.action {
            case .removePathAdmin, .adminShell: return true
            default: return false
            }
        }
        let normal = items.filter {
            switch $0.action {
            case .removePathAdmin, .adminShell: return false
            default: return true
            }
        }

        let total = Double(normal.count + (adminItems.isEmpty ? 0 : 1))
        var done = 0.0

        for item in normal {
            currentStep = item.name
            let action = Cleaner.effectiveAction(for: item)
            let res: (Bool, String?, Int64?) = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Cleaner.perform(action))
                }
            }
            // What was measured, where anything was, rather than what was
            // estimated before the run. Everything downstream — the results
            // list, the log and the lifetime total — uses the same number.
            let bytes = res.2 ?? item.bytes
            outcomes.append(CleanOutcome(itemID: item.id, name: item.name,
                                         bytes: bytes, ok: res.0, message: res.1))
            OperationLog.record(action: action, name: item.name,
                                bytes: bytes, ok: res.0, message: res.1)
            if res.0 {
                if case .trashPath = action { trashedBytes += bytes }
                else { freedBytes += bytes }
            }
            done += 1
            progress = done / total
        }

        if !adminItems.isEmpty {
            currentStep = "Waiting for administrator authorisation…"
            var parts: [String] = []
            // Elevated removal previously took whatever the scanners produced
            // and interpolated it straight into a root `rm -rf`, with neither a
            // deny check nor correct quoting. Both happen here now, before the
            // password prompt, and a path that fails is dropped rather than
            // weakening the batch.
            var refusedAdmin: [(String, String)] = []
            let paths = adminItems.compactMap { item -> String? in
                guard case .removePathAdmin(let p) = item.action else { return nil }
                if let refusal = SafePath.validate(p) {
                    refusedAdmin.append((item.name, refusal.reason)); return nil
                }
                if SafePath.isSymlink(p) {
                    refusedAdmin.append((item.name, "refused: symlink, not removed as root")); return nil
                }
                return p
            }
            if !paths.isEmpty {
                parts.append("/bin/rm -rf " + paths.map(SafePath.shellQuote).joined(separator: " "))
            }
            for item in adminItems {
                if case .adminShell(let cmd) = item.action { parts.append(cmd) }
            }
            let script = parts.joined(separator: " ; ")
            let res: Shell.Result = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Shell.runAsAdmin(script))
                }
            }
            for item in adminItems {
                // An item dropped by validation was never in the script, so it
                // must not inherit the batch's success.
                if let refusal = refusedAdmin.first(where: { $0.0 == item.name }) {
                    outcomes.append(CleanOutcome(itemID: item.id, name: item.name,
                                                 bytes: item.bytes, ok: false, message: refusal.1))
                    OperationLog.record(action: item.action, name: item.name,
                                        bytes: item.bytes, ok: false, message: refusal.1)
                    continue
                }
                // The batch runs as `rm -rf a b c ; other-command`, and a shell
                // reports the status of the last command in it. A removal that
                // failed in the middle would otherwise be recorded — and, now,
                // counted — as a success. Whether the path is still there is
                // the only answer that does not depend on that.
                var ok = res.ok
                var msg = res.ok ? nil : (res.err.isEmpty ? "authorisation cancelled" : res.err)
                // Only ever downgrades. A cancelled prompt ran nothing, so a
                // path that happens to be absent for some other reason must not
                // be turned into a success carrying the message "authorisation
                // cancelled" — and counted as bytes cleaned.
                if ok, case .removePathAdmin(let path) = item.action,
                   FileManager.default.fileExists(atPath: path) {
                    ok = false
                    msg = "still present after the administrator step"
                }
                outcomes.append(CleanOutcome(
                    itemID: item.id, name: item.name, bytes: item.bytes, ok: ok, message: msg))
                OperationLog.record(action: item.action, name: item.name,
                                    bytes: item.bytes, ok: ok, message: msg)
                if ok { freedBytes += item.bytes }
            }
            done += 1
            progress = done / total
        }

        // Prefer the real delta from the filesystem over the sum of estimates.
        // Trashed items are still on the volume, so they are not in this delta
        // and are reported on their own.
        let after = VolumeInfo.current().free
        if after > before { freedBytes = after - before }

        currentStep = ""
        progress = 1
        isRunning = false
        finished = true
    }

    /// Anything unrecoverable is moved to the Trash rather than unlinked.
    /// The user has already confirmed each permanent item individually; routing
    /// it here makes that decision reversible for as long as the Trash is left
    /// alone. Regenerable and admin items are deleted outright — they come
    /// back on their own, so reversibility would only cost disk space.
    nonisolated static func effectiveAction(for item: ScanItem) -> CleanAction {
        if case .removePath(let p) = item.action, item.tier == .permanent {
            return .trashPath(p)
        }
        return item.action
    }

    // MARK: - Action execution (background thread only)

    /// The third element is what was *actually* reclaimed, when that can be
    /// measured and differs from the item's size. `nil` means "the item's own
    /// size was right", which is true of everything that is simply removed.
    nonisolated private static func perform(_ action: CleanAction) -> (Bool, String?, Int64?) {
        switch action {

        case .removePath(let p):
            if let refusal = SafePath.validate(p) { return (false, refusal.reason, nil) }
            do {
                try FileManager.default.removeItem(atPath: p)
                return (true, nil, nil)
            } catch {
                let r = Shell.run("/bin/rm", ["-rf", p], timeout: 900)
                return r.ok ? (true, nil, nil) : (false, r.err.isEmpty ? "could not remove" : r.err, nil)
            }

        case .trashPath(let p):
            if let refusal = SafePath.validate(p) { return (false, refusal.reason, nil) }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                return (true, nil, nil)
            } catch {
                // Deliberately no rm -rf fallback. This item was routed here
                // because it cannot be recovered; quietly deleting it outright
                // would remove the one guarantee the routing exists to provide.
                return (false, "could not move to Trash", nil)
            }

        case .removePathAdmin, .adminShell:
            return (false, "handled in the batched admin step", nil)

        case .ollamaModel(let name):
            let r = Shell.tool("ollama", ["rm", name], timeout: 120)
            return r.ok ? (true, nil, nil) : (false, r.err, nil)

        case .dockerPrune:
            guard let docker = Shell.which("docker") else { return (false, "docker not found", nil) }
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
                return (false, "Docker daemon did not start", nil)
            }
            // -a removes unused images and stopped containers. No --volumes, ever.
            let r = Shell.run(docker, ["system", "prune", "-a", "-f"], timeout: 900)
            if startedByUs {
                _ = Shell.run("/usr/bin/osascript", ["-e", "quit app \"Docker\""], timeout: 30)
            }
            // Docker's own "reclaimable" column, which is what this item's size
            // came from, so no correction is needed.
            return r.ok ? (true, nil, nil) : (false, r.err, nil)

        case .gitGC(let repo):
            guard let git = Shell.which("git") else { return (false, "git not found", nil) }
            // The only action here that compacts rather than removes. The item's
            // size is the whole repository and gc reclaims a fraction of it, so
            // taking the size at face value would report a 3 GB repo as 3 GB
            // cleaned. Measuring both ends costs two `du` runs next to a gc that
            // already walked the object store.
            let gitDir = repo + "/.git"
            let before = Shell.diskUsage(gitDir)
            let r = Shell.run(git, ["-C", repo, "gc", "--prune=now"], timeout: 900)
            guard r.ok else { return (false, r.err, nil) }
            return (true, nil, max(0, before - Shell.diskUsage(gitDir)))

        case .advisory:
            return (false, "advisory only", nil)
        }
    }
}
