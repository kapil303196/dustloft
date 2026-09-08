import SwiftUI

// MARK: - Safety tiers
// The whole point of this app: never let a one-click clean touch something
// that cannot be rebuilt. Tier drives colour, copy and confirmation friction.

enum SafetyTier: String, CaseIterable, Codable {
    case regenerable   // comes back on its own (npm i, docker pull, rebuild)
    case admin         // safe, but needs an administrator prompt
    case permanent     // gone forever — opt in individually, never bulk

    var title: String {
        switch self {
        case .regenerable: return "Regenerable"
        case .admin:       return "Needs admin"
        case .permanent:   return "Permanent"
        }
    }

    var symbol: String {
        switch self {
        case .regenerable: return "arrow.clockwise.circle.fill"
        case .admin:       return "lock.fill"
        case .permanent:   return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .regenerable: return DS.safe
        case .admin:       return DS.warn
        case .permanent:   return DS.danger
        }
    }

    var soft: Color {
        switch self {
        case .regenerable: return DS.safeSoft
        case .admin:       return DS.warnSoft
        case .permanent:   return DS.dangerSoft
        }
    }

    var blurb: String {
        switch self {
        case .regenerable: return "Rebuilds itself the next time it is needed."
        case .admin:       return "Safe to remove, but macOS will ask for your password."
        case .permanent:   return "Cannot be recovered. Select each item deliberately."
        }
    }
}

// MARK: - What a row actually does when cleaned

enum CleanAction: Hashable {
    case removePath(String)          // rm -rf
    case removePathAdmin(String)     // rm -rf, via admin prompt
    case ollamaModel(String)         // ollama rm <name>
    case dockerPrune                 // docker system prune -a  (never --volumes)
    case gitGC(String)               // git gc --prune=now
    case adminShell(String)          // a vetted command, run under one admin prompt
    case advisory(String)            // shown only; the app will not run it
}

// MARK: - Git safety, learned the hard way

struct GitSafety: Hashable {
    var remoteRefCount: Int?   // nil = not checked / unreachable
    var uncommitted: Int
    var hasRemote: Bool

    /// True when this repo's history exists nowhere but here.
    var isOnlyCopy: Bool {
        guard let n = remoteRefCount else { return false }
        return n == 0
    }

    var badge: (String, String, Color)? {
        if isOnlyCopy {
            return ("Only copy — nothing pushed", "exclamationmark.shield.fill", DS.danger)
        }
        if !hasRemote {
            return ("No remote configured", "shield.slash.fill", DS.warn)
        }
        if uncommitted > 0 {
            return ("\(uncommitted) uncommitted", "pencil.circle.fill", DS.warn)
        }
        if remoteRefCount != nil {
            return ("Pushed to remote", "checkmark.shield.fill", DS.safe)
        }
        return nil
    }
}

// MARK: - A single reclaimable thing

struct ScanItem: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: String
    var bytes: Int64
    var detail: String?          // "unused 5 months", "42 folders"
    var action: CleanAction
    var tier: SafetyTier
    /// Rows a person must pick deliberately; "Select all" skips them.
    var autoSelectable: Bool = true
    var selected: Bool = false
    var git: GitSafety?

    /// Advisory rows are never selectable — we show the command, you run it.
    var isAdvisory: Bool { if case .advisory = action { return true }; return false }
}

// MARK: - Categories

enum Audience: String, Hashable {
    case everyone      // matters to any Mac owner
    case developer     // only shown when dev tooling is present
}

struct Category: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let tier: SafetyTier
    let blurb: String
    let restoreHint: String
    /// Stable hue for the storage bar. Paired with an icon so colour is never the sole cue.
    let hue: Color
    var audience: Audience = .everyone

    static let all: [Category] = [
        Category(id: "trash", title: "Trash", symbol: "trash.fill", tier: .regenerable,
                 blurb: "Items you already sent to the Trash.",
                 restoreHint: "Already discarded by you.",
                 hue: Color.adaptive(light: 0x64748B, dark: 0x94A3B8)),

        Category(id: "recordings", title: "Screen recordings", symbol: "record.circle.fill", tier: .permanent,
                 blurb: "Video files over 500 MB. Forgotten screen recordings are the single most common cause of a full Mac.",
                 restoreHint: "Not recoverable — play each one before selecting it.",
                 hue: Color.adaptive(light: 0xE11D48, dark: 0xFB7185)),

        Category(id: "creative", title: "Editing caches", symbol: "wand.and.stars", tier: .regenerable,
                 blurb: "After Effects, Premiere, Final Cut and Resolve scratch files.",
                 restoreHint: "Rebuilt when you reopen the project.",
                 hue: Color.adaptive(light: 0x9333EA, dark: 0xC084FC)),

        Category(id: "vms", title: "Virtual machines", symbol: "macwindow.on.rectangle", tier: .permanent,
                 blurb: "Parallels, UTM, CrossOver, Whisky and Android emulator images.",
                 restoreHint: "Contains real data — reinstall and reconfigure to restore.",
                 hue: Color.adaptive(light: 0x0369A1, dark: 0x38BDF8)),

        Category(id: "offlinemedia", title: "Offline media", symbol: "music.note.list", tier: .regenerable,
                 blurb: "Downloaded music, podcasts and video kept for offline playback.",
                 restoreHint: "Downloaded again when you play it.",
                 hue: Color.adaptive(light: 0x059669, dark: 0x34D399)),

        Category(id: "messages", title: "Messages attachments", symbol: "message.fill", tier: .permanent,
                 blurb: "Photos and video people sent you in Messages.",
                 restoreHint: "Not recoverable from this Mac.",
                 hue: Color.adaptive(light: 0x16A34A, dark: 0x4ADE80)),

        Category(id: "largeold", title: "Large & old files", symbol: "doc.viewfinder.fill", tier: .permanent,
                 blurb: "Files over 200 MB you have not opened in more than a year.",
                 restoreHint: "Not recoverable — check each one before selecting.",
                 hue: Color.adaptive(light: 0xB45309, dark: 0xFBBF24)),

        Category(id: "downloads", title: "Old downloads", symbol: "arrow.down.circle.fill", tier: .permanent,
                 blurb: "Anything in your Downloads folder older than 90 days.",
                 restoreHint: "Download it again if you still need it.",
                 hue: Color.adaptive(light: 0x0EA5E9, dark: 0x38BDF8)),

        Category(id: "leftovers", title: "App leftovers", symbol: "shippingbox.and.arrow.backward.fill", tier: .regenerable,
                 blurb: "Support files and caches belonging to apps no longer installed.",
                 restoreHint: "Only matters if you reinstall the app — settings would reset.",
                 hue: Color.adaptive(light: 0x7C3AED, dark: 0xA78BFA)),

        Category(id: "iosbackups", title: "Device backups", symbol: "iphone.badge.play", tier: .permanent,
                 blurb: "Local device backups made by Finder or iTunes.",
                 restoreHint: "Cannot be recovered. Check iCloud has a backup first.",
                 hue: Color.adaptive(light: 0xBE123C, dark: 0xFB7185)),

        Category(id: "mail", title: "Mail attachments", symbol: "envelope.fill", tier: .regenerable,
                 blurb: "Attachments Mail downloaded to disk.",
                 restoreHint: "Re-downloaded from the server when you open the message.",
                 hue: Color.adaptive(light: 0x0F766E, dark: 0x2DD4BF)),

        Category(id: "browsers", title: "Browser caches", symbol: "safari.fill", tier: .regenerable,
                 blurb: "Cached pages and images. Your history, passwords and bookmarks are untouched.",
                 restoreHint: "Rebuilt as you browse.",
                 hue: Color.adaptive(light: 0x1D4ED8, dark: 0x60A5FA)),

        Category(id: "logs", title: "Logs & reports", symbol: "doc.text.magnifyingglass", tier: .regenerable,
                 blurb: "Diagnostic logs written by macOS and your apps.",
                 restoreHint: "Regenerated automatically.",
                 hue: Color.adaptive(light: 0x525252, dark: 0xA3A3A3)),

        Category(id: "unusedapps", title: "Unused apps", symbol: "app.badge.checkmark", tier: .permanent,
                 blurb: "Applications not opened in over six months.",
                 restoreHint: "Reinstall from the App Store or the developer.",
                 hue: Color.adaptive(light: 0xC2410C, dark: 0xFB923C)),

        Category(id: "node_modules", title: "node_modules", symbol: "shippingbox.fill", tier: .regenerable,
                 blurb: "Dependency folders inside your project roots.",
                 restoreHint: "npm install / pnpm install",
                 hue: Color.adaptive(light: 0x2563EB, dark: 0x60A5FA), audience: .developer),

        Category(id: "build", title: "Build output", symbol: "hammer.fill", tier: .regenerable,
                 blurb: ".next, dist, build, out, target, __pycache__ and friends.",
                 restoreHint: "Rebuilt on your next build.",
                 hue: Color.adaptive(light: 0x7C3AED, dark: 0xA78BFA), audience: .developer),

        Category(id: "venv", title: "Python venvs", symbol: "chevron.left.forwardslash.chevron.right", tier: .regenerable,
                 blurb: "Virtual environments inside your project roots.",
                 restoreHint: "python -m venv + pip install -r requirements.txt",
                 hue: Color.adaptive(light: 0x0891B2, dark: 0x22D3EE), audience: .developer),

        Category(id: "devcache", title: "Developer caches", symbol: "internaldrive.fill", tier: .regenerable,
                 blurb: "~/.cache — HuggingFace, uv, puppeteer, browser binaries.",
                 restoreHint: "Re-downloaded on demand.",
                 hue: Color.adaptive(light: 0x0D9488, dark: 0x2DD4BF), audience: .developer),

        Category(id: "appcache", title: "App caches", symbol: "square.stack.3d.up.fill", tier: .regenerable,
                 blurb: "~/Library/Caches, minus anything you have excluded.",
                 restoreHint: "Apps rebuild these as you use them.",
                 hue: Color.adaptive(light: 0x059669, dark: 0x34D399)),

        Category(id: "pkgcache", title: "Package caches", symbol: "cube.box.fill", tier: .regenerable,
                 blurb: "npm, pnpm, yarn, bun, cargo, gradle and Homebrew download caches.",
                 restoreHint: "Re-downloaded on your next install.",
                 hue: Color.adaptive(light: 0xCA8A04, dark: 0xFACC15), audience: .developer),

        Category(id: "ollama", title: "Ollama models", symbol: "brain.head.profile", tier: .regenerable,
                 blurb: "Local LLM weights.",
                 restoreHint: "ollama pull <model>",
                 hue: Color.adaptive(light: 0xDB2777, dark: 0xF472B6), audience: .developer),

        Category(id: "docker", title: "Docker", symbol: "cube.transparent.fill", tier: .regenerable,
                 blurb: "Unused images, stopped containers and build cache. Volumes are never touched.",
                 restoreHint: "docker pull / docker compose up",
                 hue: Color.adaptive(light: 0x0284C7, dark: 0x38BDF8), audience: .developer),

        Category(id: "xcode", title: "Xcode leftovers", symbol: "iphone.gen3", tier: .admin,
                 blurb: "Simulator runtimes and device images.",
                 restoreHint: "Xcode re-downloads runtimes on demand.",
                 hue: Color.adaptive(light: 0xEA580C, dark: 0xFB923C), audience: .developer),

        Category(id: "nvm", title: "Node versions", symbol: "n.square.fill", tier: .regenerable,
                 blurb: "Installed nvm runtimes other than your current one.",
                 restoreHint: "nvm install <version>",
                 hue: Color.adaptive(light: 0x65A30D, dark: 0xA3E635), audience: .developer),

        Category(id: "whatsapp", title: "WhatsApp media", symbol: "photo.stack.fill", tier: .permanent,
                 blurb: "Downloaded photos, video and voice notes. Chat text is never touched.",
                 restoreHint: "Not recoverable — WhatsApp does not re-serve old media.",
                 hue: Color.adaptive(light: 0xDC2626, dark: 0xF87171)),

        Category(id: "git", title: "Git repositories", symbol: "arrow.triangle.branch", tier: .regenerable,
                 blurb: "Repack loose objects. Reclaim never deletes a .git folder.",
                 restoreHint: "Nothing is lost — gc only repacks.",
                 hue: Color.adaptive(light: 0x9333EA, dark: 0xC084FC), audience: .developer),

        Category(id: "advisory", title: "Worth a look", symbol: "info.circle.fill", tier: .admin,
                 blurb: "Things worth reclaiming that Reclaim will not do for you.",
                 restoreHint: "Run the shown command yourself.",
                 hue: Color.adaptive(light: 0x475569, dark: 0x94A3B8))
    ]

    static func find(_ id: String) -> Category {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Volume stats

struct VolumeInfo {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> VolumeInfo {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return VolumeInfo() }
        return VolumeInfo(
            total: Int64(v.volumeTotalCapacity ?? 0),
            free: v.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}
