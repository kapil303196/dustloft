import Foundation

/// The categories people actually lose hundreds of gigabytes to: forgotten
/// screen recordings, video-editing scratch caches, virtual machine disks and
/// offline media. These are the cases that show up again and again in the wild.
extension Scanners {

    private static var h: String { NSHomeDirectory() }

    // MARK: Screen recordings and oversized video

    /// Unlike "large and old", these are flagged at any age: a stray recording
    /// from last week is just as likely to be 200 GB as one from last year.
    static func screenRecordings(_ s: Settings) -> [ScanItem] {
        var out: [ScanItem] = []
        let roots = [h + "/Desktop", h + "/Movies", h + "/Documents", h + "/Downloads"]
        for root in roots where FileManager.default.fileExists(atPath: root) {
            let r = Shell.run("/usr/bin/find", [
                root, "-xdev", "-type", "f", "-size", "+500M",
                "(", "-name", "*.mov", "-o", "-name", "*.mp4", "-o",
                     "-name", "*.m4v", "-o", "-name", "*.avi", "-o", "-name", "*.mkv", ")",
                "-print"
            ], timeout: 180)
            for p in r.out.split(separator: "\n").map(String.init) {
                guard !s.isExcluded(p) else { continue }
                let size = Shell.fileSize(p)
                guard size > 0 else { continue }
                let leaf = (p as NSString).lastPathComponent
                let looksLikeRecording = leaf.lowercased().contains("screen")
                    || leaf.lowercased().contains("recording")
                out.append(ScanItem(
                    name: leaf, path: p, bytes: size,
                    detail: looksLikeRecording ? "looks like a screen recording" : "large video file",
                    action: .removePath(p), tier: .permanent, autoSelectable: false))
            }
        }
        return out
    }

    // MARK: Video and photo editing scratch caches

    static func creativeCaches(_ s: Settings) -> [ScanItem] {
        let candidates: [(String, String)] = [
            ("Adobe media cache",      h + "/Library/Application Support/Adobe/Common/Media Cache Files"),
            ("Adobe media cache DB",   h + "/Library/Application Support/Adobe/Common/Media Cache"),
            ("Adobe peak files",       h + "/Library/Application Support/Adobe/Common/Peak Files"),
            ("Adobe caches",           h + "/Library/Caches/Adobe"),
            ("After Effects disk cache", h + "/Library/Caches/Adobe/After Effects"),
            ("Premiere Pro caches",    h + "/Library/Caches/Adobe/Premiere Pro"),
            ("Final Cut render files", h + "/Movies/Final Cut Backups.localized"),
            ("DaVinci Resolve cache",  h + "/Library/Application Support/Blackmagic Design/DaVinci Resolve/CacheClip"),
            ("Blender cache",          h + "/Library/Caches/Blender")
        ]
        return candidates.compactMap { name, p in
            guard FileManager.default.fileExists(atPath: p), !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: name, path: p, bytes: size,
                            detail: "regenerated when you next open the project",
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Virtual machines, emulators and Windows compatibility layers

    static func virtualMachines(_ s: Settings) -> [ScanItem] {
        let candidates: [(String, String)] = [
            ("CrossOver bottles",     h + "/Library/Application Support/CrossOver"),
            ("Whisky bottles",        h + "/Library/Containers/com.isaacmarovitz.Whisky"),
            ("UTM virtual machines",  h + "/Library/Containers/com.utmapp.UTM"),
            ("Parallels downloads",   h + "/Library/Parallels/Downloads"),
            ("Android emulator images", h + "/Library/Android/sdk/system-images"),
            ("Android virtual devices", h + "/.android/avd"),
            ("Xcode device support",  h + "/Library/Developer/Xcode/iOS DeviceSupport"),
            ("Xcode archives",        h + "/Library/Developer/Xcode/Archives")
        ]
        return candidates.compactMap { name, p in
            guard FileManager.default.fileExists(atPath: p), !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            // A VM disk holds real work; never sweep it up automatically.
            let isVM = name.contains("machine") || name.contains("bottle") || name.contains("device")
            return ScanItem(name: name, path: p, bytes: size,
                            detail: isVM ? "contains real data — check before removing" : "re-downloaded on demand",
                            action: .removePath(p),
                            tier: isVM ? .permanent : .regenerable,
                            autoSelectable: false)
        }
    }

    // MARK: Offline music, podcasts and streamed media

    static func offlineMedia(_ s: Settings) -> [ScanItem] {
        let candidates: [(String, String)] = [
            ("Spotify offline cache", h + "/Library/Application Support/Spotify/PersistentCache"),
            ("Podcasts downloads",    h + "/Library/Group Containers/243LU875E5.groups.com.apple.podcasts"),
            ("Apple Music downloads", h + "/Library/Containers/com.apple.Music/Data/Library/Caches"),
            ("TV downloads",          h + "/Library/Containers/com.apple.TV/Data/Library/Caches")
        ]
        return candidates.compactMap { name, p in
            guard FileManager.default.fileExists(atPath: p), !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: name, path: p, bytes: size,
                            detail: "downloaded again when you play it",
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Messages attachments

    static func messagesAttachments(_ s: Settings) -> [ScanItem] {
        let p = h + "/Library/Messages/Attachments"
        guard FileManager.default.fileExists(atPath: p) else { return [] }
        let size = Shell.diskUsage(p)
        guard size > 0 else { return [] }
        return [ScanItem(name: "Photos and video sent in Messages", path: p, bytes: size,
                         detail: "removed from this Mac only — conversations stay, attachments do not come back",
                         action: .removePath(p), tier: .permanent, autoSelectable: false)]
    }

    // MARK: Advisory-only system stores

    static func systemAdvisories() -> [ScanItem] {
        var out: [ScanItem] = []

        // Spotlight's index can balloon. It rebuilds itself, but it lives on the
        // system volume, so Dustloft reports it rather than touching it.
        let spot = "/System/Volumes/Data/.Spotlight-V100"
        if FileManager.default.fileExists(atPath: spot) {
            let size = Shell.diskUsage(spot)
            if size > ScanEngine.advisoryFloor {
                out.append(ScanItem(
                    name: "Spotlight search index", path: spot, bytes: size,
                    detail: "Rebuilt automatically afterwards. Search results are briefly incomplete while it reindexes.",
                    action: .adminShell("/usr/bin/mdutil -E / >/dev/null"), tier: .admin))
            }
        }
        return out
    }
}
