import Foundation

/// Dynamic per-app discovery. No hardcoded list of applications: every app
/// data folder on the Mac is measured, named, and sorted by size, so an app
/// quietly hoarding recordings or caches surfaces on its own.
extension Scanners {

    private static var hm: String { NSHomeDirectory() }

    /// Subfolder names that are, by any app's convention, disposable.
    private static let junkNames: Set<String> = [
        "Cache", "Caches", "cache", "caches",
        "GPUCache", "Code Cache", "CachedData", "DawnCache", "DawnWebGPUCache",
        "ShaderCache", "GrShaderCache", "GPUCache", "Service Worker",
        "blob_storage", "Crashpad", "logs", "Logs", "tmp", "Temp", "temp",
        "PersistentCache", "MediaCache", "Media Cache", "CacheStorage",
        "DiskCache", "ImageCache", "http-cache", "Partitions"
    ]

    /// Roots that hold third-party application data.
    private static var appRoots: [String] {
        [hm + "/Library/Application Support",
         hm + "/Library/Containers",
         hm + "/Library/Group Containers"]
    }

    // MARK: Display names

    /// bundle id -> human app name, built from what is actually installed.
    static func installedAppNames() -> [String: String] {
        var map: [String: String] = [:]
        for dir in ["/Applications", hm + "/Applications", "/Applications/Utilities",
                    "/System/Applications", "/System/Applications/Utilities"] {
            for app in entriesPublic(dir) where app.hasSuffix(".app") {
                guard let d = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
                      let id = d["CFBundleIdentifier"] as? String else { continue }
                let name = (d["CFBundleDisplayName"] as? String)
                    ?? (d["CFBundleName"] as? String)
                    ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                map[id.lowercased()] = name
            }
        }
        return map
    }

    private static func pretty(_ folder: String, _ names: [String: String]) -> String {
        if let n = names[folder.lowercased()] { return n }
        // group.com.foo.bar / com.foo.bar -> try the underlying bundle id
        var f = folder
        if f.hasPrefix("group.") { f = String(f.dropFirst(6)) }
        if let n = names[f.lowercased()] { return n }
        // Team-prefixed group containers look like ABCDE12345.com.foo
        let parts = f.split(separator: ".")
        if parts.count > 2, parts[0].count == 10 {
            let rest = parts.dropFirst().joined(separator: ".")
            if let n = names[rest.lowercased()] { return n }
        }
        return folder
    }

    // MARK: App data — real content, always hand-picked

    static func appData(_ s: Settings) -> [ScanItem] {
        let names = installedAppNames()
        var best: [String: (String, Int64)] = [:]   // display name -> (path, bytes)

        for root in appRoots {
            let sizes = Shell.childSizes(root)
            for p in entriesPublic(root) {
                let leaf = (p as NSString).lastPathComponent
                guard !s.isExcluded(p) else { continue }
                // Apple's own plumbing is not something a person should prune here.
                guard !leaf.hasPrefix("com.apple."), !leaf.hasPrefix("group.com.apple."),
                      leaf != ".DS_Store" else { continue }
                let size = sizes[p] ?? 0
                guard size >= 100 * 1024 * 1024 else { continue }   // only what matters
                let display = pretty(leaf, names)
                // One row per app, attributed to its largest folder.
                if let existing = best[display], existing.1 >= size { continue }
                best[display] = (p, size)
            }
        }

        // Naming the heaviest subfolder costs a nested du per app, so only the
        // biggest offenders get that treatment. The rest stay cheap.
        let ranked = best.sorted { $0.value.1 > $1.value.1 }
        return ranked.enumerated().map { idx, kv in
            let (display, v) = kv
            let (path, size) = v
            return ScanItem(
                name: display, path: path, bytes: size,
                detail: idx < 12 ? describe(path)
                                 : "app data — open it before removing",
                action: .removePath(path),
                tier: .permanent, autoSelectable: false)
        }
    }

    /// Names the heaviest thing inside, so "Wispr Flow — 6 GB" becomes
    /// "6 GB, mostly Recordings" without the user having to go digging.
    private static func describe(_ path: String) -> String {
        var biggest: (String, Int64) = ("", 0)
        for (child, sz) in Shell.childSizes(path) {
            if sz > biggest.1 { biggest = ((child as NSString).lastPathComponent, sz) }
        }
        if biggest.1 > 0 {
            return "mostly “\(biggest.0)” (\(Bytes.fmt(biggest.1))) · this is app data, open it before removing"
        }
        return "app data — open it before removing"
    }

    // MARK: In-app junk — disposable by convention, safe to sweep

    static func inAppJunk(_ s: Settings) -> [ScanItem] {
        let names = installedAppNames()
        var out: [ScanItem] = []

        for root in appRoots {
            for appDir in entriesPublic(root) {
                let leaf = (appDir as NSString).lastPathComponent
                guard !s.isExcluded(appDir), leaf != ".DS_Store" else { continue }
                let display = pretty(leaf, names)

                // Look two levels down: Containers nest under Data/Library.
                var candidates = entriesPublic(appDir)
                for sub in ["/Data/Library", "/Data", "/Library"] {
                    let nested = appDir + sub
                    if FileManager.default.fileExists(atPath: nested) {
                        candidates += entriesPublic(nested)
                    }
                }

                let junk = candidates.filter {
                    junkNames.contains(($0 as NSString).lastPathComponent) && !s.isExcluded($0)
                }
                guard !junk.isEmpty else { continue }
                for c in junk {
                    let name = (c as NSString).lastPathComponent
                    let size = Shell.diskUsage(c)
                    guard size >= 25 * 1024 * 1024 else { continue }
                    out.append(ScanItem(
                        name: "\(display) — \(name)",
                        path: c, bytes: size,
                        detail: "cache inside \(display); the app rebuilds it",
                        action: .removePath(c), tier: .regenerable))
                }
            }
        }
        return out
    }
}
