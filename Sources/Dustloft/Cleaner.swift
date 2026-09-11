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
    /// Whether this may be added to a running total of space cleaned.
    ///
    /// False for work whose effect cannot be measured — a shell command run as
    /// root, where `bytes` is an estimate of what it was *asked* to reclaim and
    /// nothing afterwards can say what it actually did. Such an item is still
    /// shown and still logged; it is only kept out of the arithmetic.
    var countsAsCleaned: Bool = true
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
    /// "freed" for that reason — and counted once, at the moment it leaves the
    /// active filesystem, never again when the Trash itself is emptied.
    ///
    /// Anything whose effect could not be measured is excluded too; see
    /// `CleanOutcome.countsAsCleaned`.
    ///
    /// Deliberately not `freedBytes`: that figure is overwritten by the volume
    /// delta, which is the right number to show someone staring at their disk
    /// but the wrong one to add up, because it also counts whatever else macOS
    /// happened to do during the run. It cannot be used as a ceiling here
    /// either — an APFS snapshot routinely holds deleted space for hours, so a
    /// real 50 GB removal can show a delta of nothing.
    var accountedBytes: Int64 {
        outcomes.filter { $0.ok && $0.countsAsCleaned }.reduce(0) { $0 + $1.bytes }
    }

    /// Executes the chosen items. Admin removals are collected and run under a
    /// single authorisation prompt rather than one dialog per path.
    ///
    /// Returns false when there was nothing to do, or a run was already under
    /// way. The caller has to know the difference: crediting a cumulative total
    /// from `outcomes` after a no-op would count a run's bytes twice, and that
    /// total only ever rises.
    @discardableResult
    func run(_ items: [ScanItem]) async -> Bool {
        guard !isRunning, !items.isEmpty else { return false }
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
            let counts = Cleaner.targetPath(of: action).map { !Cleaner.isInsideTrash($0) } ?? true
            outcomes.append(CleanOutcome(itemID: item.id, name: item.name,
                                         bytes: bytes, ok: res.0, message: res.1,
                                         countsAsCleaned: counts))
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
            // Captured before the prompt. Afterwards, absence alone cannot tell
            // "this run removed it" from "it was already gone", and the second
            // would credit a scan-time estimate to a run that did nothing.
            var existedBefore: Set<String> = []
            let paths = adminItems.compactMap { item -> String? in
                guard case .removePathAdmin(let p) = item.action else { return nil }
                if let refusal = SafePath.validate(p) {
                    refusedAdmin.append((item.name, refusal.reason)); return nil
                }
                if SafePath.isSymlink(p) {
                    refusedAdmin.append((item.name, "refused: symlink, not removed as root")); return nil
                }
                if Cleaner.entryExists(p) { existedBefore.insert(p) }
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
            // A refused authorisation is distinct from a command that ran and
            // failed: osascript reports it as -128, and in that case not one
            // line of the batch executed. Everything else means the script did
            // run, and per-item truth has to come from somewhere better than
            // the exit status of whichever command was last.
            // "-128" on its own appears inside perfectly ordinary output — a
            // path called chunk-1284 is enough — and matching it loosely would
            // turn any failing command in the batch into "cancelled", which
            // skips the ground-truth check below and discards every successful
            // removal with it. The parenthesised form is osascript's.
            let lowered = res.err.lowercased()
            let cancelled = !res.ok && (lowered.contains("(-128)")
                                        || lowered.contains("user canceled")
                                        || lowered.contains("user cancelled"))

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
                let ok: Bool
                let msg: String?
                // Zeroed for anything this run did not actually remove. The
                // volume delta only overwrites freedBytes when it is positive,
                // which an APFS snapshot routinely prevents — so the results
                // screen would otherwise be free to claim gigabytes for a path
                // that was gone before the prompt was ever shown.
                var bytes = item.bytes
                // A shell command has no path to check afterwards, so it keeps
                // the batch's exit status — which, for `a ; b`, is b's. The two
                // that reach here (`tmutil thinlocalsnapshots`, `mdutil -E`)
                // also carry an estimate of what they were asked to reclaim
                // rather than a measurement of what they did, so neither the
                // status nor the size can be trusted in a total that is
                // published. Shown and logged as before; not counted.
                var counts = true
                if case .adminShell = item.action { counts = false }
                // A root-owned file in the Trash arrives here rather than on
                // the path above, and is the same double-count either way.
                if let p = Cleaner.targetPath(of: item.action), Cleaner.isInsideTrash(p) {
                    counts = false
                }

                if cancelled {
                    // Nothing in the batch ran, so nothing in it succeeded —
                    // whatever the filesystem happens to look like.
                    ok = false
                    msg = "authorisation cancelled"
                } else if case .removePathAdmin(let path) = item.action {
                    if !existedBefore.contains(path) {
                        // Gone before the prompt. The row should still clear,
                        // but this run did not reclaim it.
                        ok = true
                        msg = "already gone"
                        counts = false
                        bytes = 0
                    } else {
                        // The path is the ground truth, in both directions. The
                        // batch is `rm -rf … ; cmd1 ; cmd2` and a shell reports
                        // the LAST command's status, so a failing mdutil marks a
                        // perfectly successful rm as failed exactly as readily
                        // as the reverse. Asking the filesystem is the only
                        // answer that does not depend on what came last.
                        ok = !Cleaner.entryExists(path)
                        msg = ok ? nil : (res.ok ? "still present after the administrator step"
                                                 : (res.err.isEmpty ? "could not remove" : res.err))
                    }
                } else {
                    ok = res.ok
                    msg = res.ok ? nil : (res.err.isEmpty ? "could not run" : res.err)
                }
                outcomes.append(CleanOutcome(
                    itemID: item.id, name: item.name, bytes: bytes, ok: ok,
                    message: msg, countsAsCleaned: counts))
                OperationLog.record(action: item.action, name: item.name,
                                    bytes: bytes, ok: ok, message: msg)
                if ok { freedBytes += bytes }
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
        return true
    }

    /// Anything unrecoverable is moved to the Trash rather than unlinked.
    /// The user has already confirmed each permanent item individually; routing
    /// it here makes that decision reversible for as long as the Trash is left
    /// alone. Regenerable and admin items are deleted outright — they come
    /// back on their own, so reversibility would only cost disk space.
    ///
    /// The exception is something already in the Trash, which has nowhere
    /// further to go: emptying it unlinks. The review sheet says so in place of
    /// the usual "stays recoverable" promise whenever such a row is ticked.
    nonisolated static func effectiveAction(for item: ScanItem) -> CleanAction {
        if case .removePath(let p) = item.action, item.tier == .permanent {
            // Except when it is already there. Trash rows are permanent-tier
            // too, so this used to hand `trashItem` a file inside ~/.Trash —
            // which either fails with "could not move to Trash" or shuffles it
            // around inside, clearing the row while the file returns on the
            // next scan. Emptying the Trash is the one case where a permanent
            // item really is meant to be unlinked, and it is the case the user
            // confirmed individually.
            if isInsideTrash(p) { return item.action }
            return .trashPath(p)
        }
        return item.action
    }

    /// The "Total reclaimed space: 10.79GB" line `docker system prune` prints.
    ///
    /// Returns 0 rather than the scan estimate when the line is missing, on the
    /// same principle as the git gc measurement: a figure that is published is
    /// either measured or not counted.
    nonisolated static func dockerReclaimed(_ output: String) -> Int64 {
        for line in output.split(separator: "\n")
        where line.lowercased().contains("total reclaimed space") {
            return Scanners.parseDockerSize(line.split(separator: " ").map(String.init)) ?? 0
        }
        return 0
    }

    /// The filesystem path an action operates on, where it has one.
    nonisolated static func targetPath(of action: CleanAction) -> String? {
        switch action {
        case .removePath(let p), .trashPath(let p), .removePathAdmin(let p), .gitGC(let p):
            return p
        case .ollamaModel, .dockerPrune, .adminShell, .advisory:
            return nil
        }
    }

    /// Whether a path is already inside a Trash.
    ///
    /// This is the one place the same bytes can be billed twice. Dustloft moves
    /// a permanent-tier item to the Trash and counts it, the next scan finds
    /// that file in the Trash and offers it again, and emptying it there would
    /// count it a second time for work that frees the space once. The rule is
    /// that the moment it leaves the active filesystem is the moment it counts,
    /// and the Trash never counts.
    ///
    /// A component match rather than a prefix, so per-volume `.Trashes` is
    /// covered too. A directory genuinely called `.Trash` elsewhere would go
    /// uncounted, which is the harmless direction.
    nonisolated static func isInsideTrash(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// Whether there is an entry at this path at all.
    ///
    /// `attributesOfItem` rather than `fileExists`, for the reason below: it
    /// reports *why* it could not answer, and "there is nothing here" has to be
    /// told apart from "I could not look". It also does not follow symlinks, so
    /// a dangling one reads as present — which it is, and it still needs
    /// removing.
    nonisolated static func entryExists(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return true
        } catch let error as NSError {
            // Only "there is nothing here" means gone. Anything else — an
            // unmounted volume, a stale mount, a permission wall — is a
            // question that could not be answered, and answering it "absent"
            // turns a failure into a successful clean and, where this gates
            // the "already gone" shortcut, skips the attempt entirely.
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                return false
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
                return false
            }
            return true
        }
    }

    // MARK: - Action execution (background thread only)

    /// The third element is what was *actually* reclaimed, when that can be
    /// measured and differs from the item's size. `nil` means "the item's own
    /// size was right", which is true of everything that is simply removed.
    nonisolated private static func perform(_ action: CleanAction) -> (Bool, String?, Int64?) {
        switch action {

        case .removePath(let p):
            if let refusal = SafePath.validate(p) { return (false, refusal.reason, nil) }
            // Gone since the scan — emptied by hand, or by the app that owns
            // it. `rm -rf` exits 0 on a path that is not there, so without this
            // the scan-time estimate would be banked as space this run
            // reclaimed. It is still a success: the row should disappear.
            guard entryExists(p) else { return (true, "already gone", 0) }
            do {
                try FileManager.default.removeItem(atPath: p)
                return (true, nil, nil)
            } catch {
                let r = Shell.run("/bin/rm", ["-rf", p], timeout: 900)
                return r.ok ? (true, nil, nil) : (false, r.err.isEmpty ? "could not remove" : r.err, nil)
            }

        case .trashPath(let p):
            if let refusal = SafePath.validate(p) { return (false, refusal.reason, nil) }
            // Same as above: gone since the scan is a success with nothing to
            // its name, not the failure trashItem would otherwise report — and
            // the row has to clear either way.
            guard entryExists(p) else { return (true, "already gone", 0) }
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
            guard r.ok else { return (false, r.err, nil) }
            // The item's size came from `docker system df` at scan time, and
            // results are cached between launches — so by now it can be well
            // out of date in either direction. Prune prints what it actually
            // freed, and that is a measurement rather than an estimate.
            return (true, nil, dockerReclaimed(r.out))

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
            let after = Shell.diskUsage(gitDir)
            // diskUsage cannot tell "empty" from "du failed" — both come back
            // as 0 — and a .git small enough to genuinely be zero was never
            // offered here in the first place. So an unreadable measurement
            // counts as nothing reclaimed. Guessing in the other direction
            // would file the entire repository as cleaned, in a total that
            // only ever rises and then gets reported.
            guard before > 0, after > 0, after < before else { return (true, nil, 0) }
            return (true, nil, before - after)

        case .advisory:
            return (false, "advisory only", nil)
        }
    }
}
