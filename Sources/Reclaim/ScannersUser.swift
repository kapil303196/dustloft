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

    static func largeOld(_ s: Settings) -> [ScanItem] {
        // Deliberately skips ~/Library — system plumbing is covered by other
        // categories and is not something a person should pick through here.
        let r = Shell.run("/usr/bin/find", [
            userHome, "-xdev", "-type", "f", "-size", "+200M",
            "-not", "-path", userHome + "/Library/*",
            "-mtime", "+365", "-print"
        ], timeout: 300)

        return r.out.split(separator: "\n").map(String.init).compactMap { p in
            guard !s.isExcluded(p) else { return nil }
            let size = Shell.fileSize(p)
            guard size > 0 else { return nil }
            let months = daysOld(p) / 30
            return ScanItem(name: (p as NSString).lastPathComponent, path: p, bytes: size,
                            detail: "not opened in about \(months) months",
                            action: .removePath(p), tier: .permanent, autoSelectable: false)
        }
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
        for dir in ["/Applications", userHome + "/Applications",
                    "/Applications/Utilities", "/System/Applications"] {
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

    /// Directory listing that tolerates permission errors (used by user scanners).
    static func entriesPublic(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .map { dir + "/" + $0 } ?? []
    }
}
