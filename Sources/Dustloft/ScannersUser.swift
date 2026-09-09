import Foundation

/// Scanners aimed at every Mac owner, not just developers.
extension Scanners {

    private static var userHome: String { NSHomeDirectory() }
    private static func age(_ path: String) -> Date? {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return (a?[.modificationDate] as? Date)
    }
    private static func daysOld(_ path: String) -> Int {
        guard let d = age(path) else { return 0 }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
    }

    // MARK: Large and old files

    /// Big files anywhere in the home folder that have not been touched in a
    /// long time.
    ///
    /// Three things make this harder than it looks:
    ///  * Apparent size lies for sparse files. Docker.raw reports 460 GB while
    ///    occupying 8.8 GB, so allocated blocks are used instead.
    ///  * `kMDItemLastUsedDate` is absent for most files, so it cannot be the
    ///    only signal; the newest of access and modification time is used.
    ///  * Spotlight finds candidates far faster than walking the disk, but it
    ///    may be disabled, so there is a `find` fallback.
    static func largeOld(_ s: Settings) -> [ScanItem] {
        let minBytes = Int64(s.largeFileMinMB) * 1024 * 1024
        let cutoff = Date().addingTimeInterval(-Double(s.largeFileMinDays) * 86_400)

        var candidates = spotlightCandidates(minBytes: minBytes)
        if candidates.isEmpty {
            candidates = findCandidates(minBytes: minBytes)
        }

        var out: [ScanItem] = []
        for p in candidates {
            guard !s.isExcluded(p) else { continue }
            let size = Shell.allocatedSize(p)
            guard size >= minBytes else { continue }          // sparse files fail here

            // Cheap filesystem check first. Only a file that already looks old
            // is worth an mdls call, which spawns a process per file.
            guard let modified = Shell.modifiedAt(p), modified < cutoff else { continue }
            // Spotlight may know the person opened it more recently than it was
            // last written, in which case it is not stale after all.
            let opened = Shell.spotlightLastUsed(p)
            if let opened, opened >= cutoff { continue }
            let used = opened ?? modified

            let days = Calendar.current.dateComponents([.day], from: used, to: Date()).day ?? 0
            let months = days / 30
            let howLong = months >= 12
                ? "about \(months / 12) year\(months / 12 == 1 ? "" : "s")"
                : "about \(max(months, 1)) month\(months == 1 ? "" : "s")"
            out.append(ScanItem(
                name: (p as NSString).lastPathComponent,
                path: p, bytes: size,
                detail: opened != nil ? "last opened \(howLong) ago"
                                      : "unchanged for \(howLong)",
                action: .removePath(p), tier: .permanent, autoSelectable: false))
        }
        return out
    }

    private static func spotlightCandidates(minBytes: Int64) -> [String] {
        let q = "kMDItemFSSize > \(minBytes)"
        let r = Shell.run("/usr/bin/mdfind", ["-onlyin", userHome, q], timeout: 120)
        guard r.ok else { return [] }
        return r.out.split(separator: "\n").map(String.init)
    }

    private static func findCandidates(minBytes: Int64) -> [String] {
        let mb = max(1, minBytes / (1024 * 1024))
        let r = Shell.run("/usr/bin/find", [
            userHome, "-xdev", "-type", "f", "-size", "+\(mb)M", "-print"
        ], timeout: 600)
        return r.out.split(separator: "\n").map(String.init)
    }

    // MARK: Old downloads

    static func oldDownloads(_ s: Settings) -> [ScanItem] {
        let dir = userHome + "/Downloads"
        let sizes = Shell.childSizes(dir)
        return entriesPublic(dir).compactMap { p in
            guard !s.isExcluded(p) else { return nil }
            let d = daysOld(p)
            guard d >= 90 else { return nil }
            let size = sizes[p] ?? 0
            guard size > 0 else { return nil }
            return ScanItem(name: (p as NSString).lastPathComponent, path: p, bytes: size,
                            detail: "\(d) days old",
                            action: .removePath(p), tier: .permanent, autoSelectable: false)
        }
    }

    // MARK: Leftovers from apps that are no longer installed

    static func leftovers(_ s: Settings) -> [ScanItem] {
        let installed = installedBundleIDs()
        guard !installed.isEmpty else { return [] }   // never guess with no baseline

        let roots = [
            userHome + "/Library/Application Support",
            userHome + "/Library/Containers",
            userHome + "/Library/Caches",
            userHome + "/Library/Saved Application State"
        ]
        var out: [ScanItem] = []
        for root in roots {
            let sizes = Shell.childSizes(root)
            for p in entriesPublic(root) {
                let leaf = (p as NSString).lastPathComponent
                // Only consider reverse-DNS folders — those map to a bundle id.
                guard leaf.contains("."), leaf.split(separator: ".").count >= 3 else { continue }
                guard !leaf.hasPrefix("com.apple."), !s.isExcluded(p) else { continue }
                let base = leaf
                    .replacingOccurrences(of: ".savedState", with: "")
                    .replacingOccurrences(of: ".ShipIt", with: "")
                guard !installed.contains(base.lowercased()) else { continue }
                let size = sizes[p] ?? 0
                guard size > 0 else { continue }
                out.append(ScanItem(name: leaf, path: p, bytes: size,
                                    detail: "no installed app matches this identifier",
                                    action: .removePath(p), tier: .regenerable,
                                    autoSelectable: false))
            }
        }
        return out
    }

    private static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        // Anything missing here is read as an app that is no longer installed,
        // and its data becomes a deletion candidate. Under-counting install
        // locations is therefore how live app data gets offered up as junk, so
        // this list errs wide: Setapp keeps its apps in a subfolder, and
        // Homebrew casks live under a versioned Caskroom path.
        var roots = ["/Applications", userHome + "/Applications",
                     "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities",
                     "/Applications/Setapp", userHome + "/Applications/Setapp"]
        for caskroom in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        where FileManager.default.fileExists(atPath: caskroom) {
            let found = Shell.run("/usr/bin/find",
                                  [caskroom, "-maxdepth", "3", "-name", "*.app",
                                   "-type", "d", "-prune"], timeout: 30)
            roots += found.out.split(separator: "\n").map { ($0 as NSString).deletingLastPathComponent }
        }
        for dir in Set(roots) {
            for app in entriesPublic(dir) where app.hasSuffix(".app") {
                let plist = app + "/Contents/Info.plist"
                if let d = NSDictionary(contentsOfFile: plist),
                   let id = d["CFBundleIdentifier"] as? String {
                    ids.insert(id.lowercased())
                }
            }
        }
        return ids
    }

    // MARK: iPhone / iPad backups

    static func iosBackups(_ s: Settings) -> [ScanItem] {
        let dir = userHome + "/Library/Application Support/MobileSync/Backup"
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        let sizes = Shell.childSizes(dir)
        return entriesPublic(dir).compactMap { p in
            let size = sizes[p] ?? 0
            guard size > 0 else { return nil }
            let d = daysOld(p)
            return ScanItem(name: "Device backup " + (p as NSString).lastPathComponent.prefix(8),
                            path: p, bytes: size,
                            detail: "last updated \(d) days ago · confirm iCloud has a backup first",
                            action: .removePath(p), tier: .permanent, autoSelectable: false)
        }
    }

    // MARK: Mail attachments

    static func mail(_ s: Settings) -> [ScanItem] {
        let candidates = [
            userHome + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            userHome + "/Library/Mail Downloads"
        ]
        return candidates.compactMap { p in
            guard FileManager.default.fileExists(atPath: p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: "Mail Downloads", path: p, bytes: size,
                            detail: "re-downloaded when you reopen the message",
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Browser caches — Brave is excluded by user policy

    static func browsers(_ s: Settings) -> [ScanItem] {
        let map: [(String, String)] = [
            ("Google Chrome", userHome + "/Library/Caches/Google/Chrome"),
            ("Safari",        userHome + "/Library/Caches/com.apple.Safari"),
            ("Firefox",       userHome + "/Library/Caches/Firefox"),
            ("Microsoft Edge",userHome + "/Library/Caches/Microsoft Edge"),
            ("Arc",           userHome + "/Library/Caches/company.thebrowser.Browser")
        ]
        return map.compactMap { name, p in
            guard FileManager.default.fileExists(atPath: p), !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: name, path: p, bytes: size,
                            detail: "history, passwords and bookmarks are not affected",
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Logs

    static func logs(_ s: Settings) -> [ScanItem] {
        let paths = [
            userHome + "/Library/Logs",
            userHome + "/Library/Application Support/CrashReporter"
        ]
        return paths.compactMap { p in
            guard FileManager.default.fileExists(atPath: p), !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: shortenPath(p), path: p, bytes: size, detail: nil,
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Apps not opened in a long time

    static func unusedApps(_ s: Settings) -> [ScanItem] {
        var out: [ScanItem] = []
        for app in entriesPublic("/Applications") where app.hasSuffix(".app") {
            let md = Shell.run("/usr/bin/mdls",
                               ["-name", "kMDItemLastUsedDate", "-raw", app], timeout: 15).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard md != "(null)", !md.isEmpty else { continue }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            guard let used = fmt.date(from: md) else { continue }
            let days = Calendar.current.dateComponents([.day], from: used, to: Date()).day ?? 0
            guard days > 180 else { continue }
            let size = Shell.diskUsage(app)
            guard size > 100 * 1024 * 1024 else { continue }
            let rootOwned = (try? FileManager.default.attributesOfItem(atPath: app))
                .flatMap { $0[.ownerAccountName] as? String }.map { $0 != NSUserName() } ?? false
            out.append(ScanItem(
                name: (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                path: app, bytes: size,
                detail: "last opened \(days / 30) months ago",
                action: rootOwned ? .removePathAdmin(app) : .removePath(app),
                tier: .permanent, autoSelectable: false))
        }
        return out
    }

    /// Directory listing that tolerates a missing directory but still reports
    /// permission failures, so the UI can explain why sizes look too small.
    static func entriesPublic(_ dir: String) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: dir).map { dir + "/" + $0 }
        } catch {
            if (error as NSError).code == NSFileReadNoPermissionError { sawPermissionError = true }
            return []
        }
    }
}
