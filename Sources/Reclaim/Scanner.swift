import Foundation
import SwiftUI

@MainActor
final class ScanEngine: ObservableObject {

    @Published var items: [String: [ScanItem]] = [:]
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var volume = VolumeInfo.current()
    @Published var lastScan: Date?
    @Published var permissionDenied = false

    let settings: Settings
    init(settings: Settings) { self.settings = settings }

    /// Anything smaller than this is noise in a disk-cleanup UI.
    private static let floor: Int64 = 8 * 1024 * 1024

    var totalSelected: Int64 {
        items.values.flatMap { $0 }.filter { $0.selected }.reduce(0) { $0 + $1.bytes }
    }
    var selectedItems: [ScanItem] {
        items.values.flatMap { $0 }.filter { $0.selected }
    }
    var totalFound: Int64 {
        items.values.flatMap { $0 }.filter { !$0.isAdvisory }.reduce(0) { $0 + $1.bytes }
    }

    func setSelection(_ id: UUID, _ on: Bool) {
        for (k, list) in items {
            if let i = list.firstIndex(where: { $0.id == id }) {
                items[k]?[i].selected = on
                return
            }
        }
    }

    func selectAll(in category: String, _ on: Bool) {
        guard var list = items[category] else { return }
        for i in list.indices where !list[i].isAdvisory {
            // Permanent and hand-pick-only rows are never bulk-selected.
            if on && (list[i].tier == .permanent || !list[i].autoSelectable) { continue }
            list[i].selected = on
        }
        items[category] = list
    }

    // MARK: - Scan

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        items = [:]
        permissionDenied = false

        let s = settings
        let roots = settings.projectRoots

        let jobs: [(String, String, () -> [ScanItem])] = [
            ("trash",        "Trash",              { Scanners.trash(s) }),
            ("leftovers",    "app leftovers",      { Scanners.leftovers(s) }),
            ("downloads",    "old downloads",      { Scanners.oldDownloads(s) }),
            ("browsers",     "browser caches",     { Scanners.browsers(s) }),
            ("mail",         "Mail attachments",   { Scanners.mail(s) }),
            ("logs",         "logs",               { Scanners.logs(s) }),
            ("iosbackups",   "device backups",     { Scanners.iosBackups(s) }),
            ("largeold",     "large and old files",{ Scanners.largeOld(s) }),
            ("unusedapps",   "unused apps",        { Scanners.unusedApps(s) }),
            ("node_modules", "node_modules",       { Scanners.projectDirs(roots, ["node_modules"], "node_modules", s) }),
            ("build",        "build output",       { Scanners.buildArtifacts(roots, s) }),
            ("venv",         "Python venvs",       { Scanners.projectDirs(roots, [".venv", "venv"], "venv", s) }),
            ("devcache",     "developer caches",   { Scanners.devCaches(s) }),
            ("appcache",     "app caches",         { Scanners.appCaches(s) }),
            ("pkgcache",     "package caches",     { Scanners.pkgCaches(s) }),
            ("ollama",       "Ollama models",      { Scanners.ollama() }),
            ("docker",       "Docker",             { Scanners.docker() }),
            ("xcode",        "Xcode leftovers",    { Scanners.xcode(s) }),
            ("nvm",          "Node versions",      { Scanners.nvm(s) }),
            ("whatsapp",     "WhatsApp media",     { Scanners.whatsapp(s) }),
            ("git",          "Git repositories",   { Scanners.gitRepos(roots, s) }),
            ("advisory",     "system items",       { Scanners.advisories() })
        ]

        let total = Double(jobs.count)
        var collected: [String: [ScanItem]] = [:]

        for (idx, job) in jobs.enumerated() {
            progressText = "Scanning \(job.1)…"
            let found: [ScanItem] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: job.2())
                }
            }
            let kept = found
                .filter { $0.isAdvisory || $0.bytes >= ScanEngine.floor }
                .sorted { $0.bytes > $1.bytes }
            if !kept.isEmpty { collected[job.0] = kept }
            items = collected
            progress = Double(idx + 1) / total
        }

        if Scanners.sawPermissionError { permissionDenied = true }
        volume = VolumeInfo.current()
        lastScan = Date()
        progressText = ""
        isScanning = false
    }
}

// MARK: - The individual scanners
// All of these run off the main thread and must never mutate UI state.

enum Scanners {

    nonisolated(unsafe) static var sawPermissionError = false
    private static let home = NSHomeDirectory()

    private static func entries(of dir: String) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: dir).map { dir + "/" + $0 }
        } catch {
            let ns = error as NSError
            if ns.code == NSFileReadNoPermissionError { sawPermissionError = true }
            return []
        }
    }

    private static func isRootOwned(_ path: String) -> Bool {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let owner = a?[.ownerAccountName] as? String
        return owner != nil && owner != NSUserName()
    }

    // MARK: Trash

    static func trash(_ s: Settings) -> [ScanItem] {
        let dir = home + "/.Trash"
        return entries(of: dir).compactMap { p in
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            let admin = isRootOwned(p)
            return ScanItem(
                name: (p as NSString).lastPathComponent,
                path: p, bytes: size,
                detail: admin ? "owned by root" : nil,
                action: admin ? .removePathAdmin(p) : .removePath(p),
                tier: admin ? .admin : .regenerable
            )
        }
    }

    // MARK: Project-scoped directory sweeps

    /// Only ever runs inside configured project roots — never across $HOME or /.
    static func projectDirs(_ roots: [String], _ names: [String], _ label: String, _ s: Settings) -> [ScanItem] {
        var out: [ScanItem] = []
        for root in roots where FileManager.default.fileExists(atPath: root) {
            var args = [root, "-type", "d", "("]
            for (i, n) in names.enumerated() {
                if i > 0 { args.append("-o") }
                args += ["-name", n]
            }
            args += [")", "-prune", "-print"]
            let r = Shell.run("/usr/bin/find", args, timeout: 300)
            for line in r.out.split(separator: "\n").map(String.init) {
                guard !s.isExcluded(line) else { continue }
                let size = Shell.diskUsage(line)
                guard size > 0 else { continue }
                out.append(ScanItem(
                    name: shortenPath(line),
                    path: line, bytes: size, detail: nil,
                    action: .removePath(line), tier: .regenerable
                ))
            }
        }
        return out
    }

    static func buildArtifacts(_ roots: [String], _ s: Settings) -> [ScanItem] {
        projectDirs(roots,
                    [".next", "dist", "build", "out", "target", "__pycache__",
                     ".turbo", ".nuxt", "coverage", ".parcel-cache"],
                    "build", s)
    }

    // MARK: Caches

    static func devCaches(_ s: Settings) -> [ScanItem] {
        entries(of: home + "/.cache").compactMap { p in
            guard !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: (p as NSString).lastPathComponent, path: p, bytes: size,
                            detail: nil, action: .removePath(p), tier: .regenerable)
        }
    }

    static func appCaches(_ s: Settings) -> [ScanItem] {
        entries(of: home + "/Library/Caches").compactMap { p in
            guard !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: (p as NSString).lastPathComponent, path: p, bytes: size,
                            detail: nil, action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Package manager caches

    static func pkgCaches(_ s: Settings) -> [ScanItem] {
        let candidates = [
            home + "/.npm/_cacache",
            home + "/.yarn/cache",
            home + "/.bun/install/cache",
            home + "/.cargo/registry/cache",
            home + "/.gradle/caches",
            home + "/.m2/repository",
            home + "/Library/pnpm/store",
            home + "/Library/Caches/Homebrew",
            home + "/Library/Caches/pnpm"
        ]
        return candidates.compactMap { p in
            guard FileManager.default.fileExists(atPath: p), !s.isExcluded(p) else { return nil }
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: shortenPath(p), path: p, bytes: size, detail: nil,
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: Ollama

    static func ollama() -> [ScanItem] {
        let r = Shell.tool("ollama", ["list"], timeout: 30)
        guard r.ok else { return [] }
        var out: [ScanItem] = []
        for line in r.out.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 4 else { continue }
            let name = cols[0]
            // "4.9 GB" -> bytes
            guard let val = Double(cols[2]) else { continue }
            let unit = cols[3].uppercased()
            let mult: Double = unit.hasPrefix("TB") ? 1e12 : unit.hasPrefix("GB") ? 1e9
                             : unit.hasPrefix("MB") ? 1e6 : 1e3
            let modified = cols.count > 4 ? cols[4...].joined(separator: " ") : nil
            out.append(ScanItem(name: name, path: "ollama:" + name,
                                bytes: Int64(val * mult),
                                detail: modified.map { "last used \($0)" },
                                action: .ollamaModel(name), tier: .regenerable))
        }
        return out
    }

    // MARK: Docker — volumes are never in scope

    static func docker() -> [ScanItem] {
        guard Shell.which("docker") != nil else { return [] }
        let info = Shell.tool("docker", ["info"], timeout: 20)
        guard info.ok else {
            return [ScanItem(name: "Docker daemon is not running", path: "docker",
                             bytes: 0, detail: "Start Docker Desktop, then scan again to see reclaimable space",
                             action: .advisory("open -a Docker"), tier: .regenerable)]
        }
        let df = Shell.tool("docker", ["system", "df"], timeout: 60)
        guard df.ok else { return [] }
        var reclaimable: Int64 = 0
        var parts: [String] = []
        for line in df.out.split(separator: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Images") || t.hasPrefix("Containers") || t.hasPrefix("Build Cache") else { continue }
            let cols = t.split(separator: " ").map(String.init)
            guard let last = cols.last(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) ?? cols.last
            else { continue }
            // reclaimable column looks like "10.79GB" possibly followed by "(50%)"
            let raw = cols.first(where: { $0.contains("GB") || $0.contains("MB") || $0.contains("kB") }) ?? last
            _ = raw
            if let b = parseDockerSize(cols) { reclaimable += b; parts.append(t.split(separator: " ")[0].description) }
        }
        guard reclaimable > 0 else { return [] }
        return [ScanItem(name: "Unused images, stopped containers, build cache",
                         path: "docker://prune", bytes: reclaimable,
                         detail: "Named volumes are never removed",
                         action: .dockerPrune, tier: .regenerable)]
    }

    private static func parseDockerSize(_ cols: [String]) -> Int64? {
        // The reclaimable figure is the last size-looking token on the row.
        for tok in cols.reversed() {
            let t = tok.replacingOccurrences(of: "(", with: "")
            guard let m = t.range(of: #"^([0-9.]+)(TB|GB|MB|kB|B)$"#, options: .regularExpression) else { continue }
            let str = String(t[m])
            let num = str.prefix { $0.isNumber || $0 == "." }
            guard let v = Double(num) else { continue }
            let unit = str.dropFirst(num.count)
            let mult: Double = unit == "TB" ? 1e12 : unit == "GB" ? 1e9 : unit == "MB" ? 1e6 : unit == "kB" ? 1e3 : 1
            return Int64(v * mult)
        }
        return nil
    }

    // MARK: Xcode

    static func xcode(_ s: Settings) -> [ScanItem] {
        var out: [ScanItem] = []
        let userPaths = [
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/CoreSimulator/Devices"
        ]
        for p in userPaths where FileManager.default.fileExists(atPath: p) {
            let size = Shell.diskUsage(p)
            guard size > 0 else { continue }
            out.append(ScanItem(name: shortenPath(p), path: p, bytes: size, detail: nil,
                                action: .removePath(p), tier: .regenerable))
        }
        let adminPaths = [
            "/Library/Developer/CoreSimulator/Caches",
            "/Library/Developer/CoreSimulator/Profiles/Runtimes"
        ]
        let xcodeInstalled = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        for p in adminPaths where FileManager.default.fileExists(atPath: p) {
            let size = Shell.diskUsage(p)
            guard size > 0 else { continue }
            out.append(ScanItem(name: p, path: p, bytes: size,
                                detail: xcodeInstalled ? nil : "orphaned — Xcode is not installed",
                                action: .removePathAdmin(p), tier: .admin))
        }
        return out
    }

    // MARK: nvm

    static func nvm(_ s: Settings) -> [ScanItem] {
        let base = home + "/.nvm/versions/node"
        guard FileManager.default.fileExists(atPath: base) else { return [] }
        let current = Shell.tool("node", ["-v"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries(of: base).compactMap { p in
            let v = (p as NSString).lastPathComponent
            guard v != current else { return nil }   // never offer the active runtime
            let size = Shell.diskUsage(p)
            guard size > 0 else { return nil }
            return ScanItem(name: v, path: p, bytes: size, detail: "not your active version (\(current))",
                            action: .removePath(p), tier: .regenerable)
        }
    }

    // MARK: WhatsApp — permanent tier

    static func whatsapp(_ s: Settings) -> [ScanItem] {
        let media = home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"
        guard FileManager.default.fileExists(atPath: media) else { return [] }
        let chats = entries(of: media).count
        let size = Shell.diskUsage(media)
        guard size > 0 else { return [] }
        return [ScanItem(name: "Downloaded media in all chats", path: media, bytes: size,
                         detail: "\(chats) chat folders · chat text is not affected",
                         action: .removePath(media), tier: .permanent)]
    }

    // MARK: Git — never offers deletion, only gc

    static func gitRepos(_ roots: [String], _ s: Settings) -> [ScanItem] {
        guard let git = Shell.which("git") else { return [] }
        var out: [ScanItem] = []
        for root in roots where FileManager.default.fileExists(atPath: root) {
            let r = Shell.run("/usr/bin/find", [root, "-type", "d", "-name", ".git", "-prune", "-print"], timeout: 300)
            for gitDir in r.out.split(separator: "\n").map(String.init) {
                guard !s.isExcluded(gitDir) else { continue }
                let size = Shell.diskUsage(gitDir)
                guard size >= 100 * 1024 * 1024 else { continue }   // only repos worth repacking
                let repo = (gitDir as NSString).deletingLastPathComponent

                let dirty = Shell.run(git, ["-C", repo, "status", "--porcelain"], timeout: 30)
                    .out.split(separator: "\n").count
                let remoteURL = Shell.run(git, ["-C", repo, "remote", "get-url", "origin"], timeout: 15)
                let hasRemote = remoteURL.ok && !remoteURL.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                // The check that matters: does this history exist anywhere else?
                var refs: Int? = nil
                if hasRemote {
                    let ls = Shell.run("/usr/bin/env", [
                        "GIT_TERMINAL_PROMPT=0",
                        "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=8",
                        git, "-C", repo, "ls-remote", "origin"
                    ], timeout: 25)
                    if ls.ok { refs = ls.out.split(separator: "\n").filter { !$0.isEmpty }.count }
                }

                let safety = GitSafety(remoteRefCount: refs, uncommitted: dirty, hasRemote: hasRemote)
                out.append(ScanItem(
                    name: shortenPath(repo),
                    path: gitDir, bytes: size,
                    detail: "repack loose objects — no history is lost",
                    action: .gitGC(repo), tier: .regenerable, git: safety
                ))
            }
        }
        return out
    }

    // MARK: Advisory — shown, never executed

    static func advisories() -> [ScanItem] {
        var out: [ScanItem] = []

        // MySQL binary logs
        let mysqlDir = "/opt/homebrew/var/mysql"
        if FileManager.default.fileExists(atPath: mysqlDir) {
            let logs = (try? FileManager.default.contentsOfDirectory(atPath: mysqlDir))?
                .filter { $0.hasPrefix("binlog.") && !$0.hasSuffix(".index") } ?? []
            let total = logs.reduce(Int64(0)) { $0 + Shell.fileSize(mysqlDir + "/" + $1) }
            if total > ScanEngine.advisoryFloor {
                out.append(ScanItem(
                    name: "MySQL binary logs", path: mysqlDir, bytes: total,
                    detail: "Purge through the server so binlog.index stays consistent. Your databases are untouched.",
                    action: .advisory(#"mysql -u root -p -e "PURGE BINARY LOGS BEFORE NOW();""#),
                    tier: .admin))
            }
        }

        // Time Machine local snapshots
        let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30)
        let names = snaps.out.split(separator: "\n")
            .filter { $0.contains("com.apple") }
        if names.count > 0 {
            out.append(ScanItem(
                name: "\(names.count) local Time Machine snapshot\(names.count == 1 ? "" : "s")",
                path: "/", bytes: 0,
                detail: "These are usually small and macOS reclaims them automatically under pressure.",
                action: .advisory("tmutil deletelocalsnapshots <date>"), tier: .admin))
        }
        return out
    }

    // MARK: Helpers

    static func shortenPath(_ p: String) -> String {
        var s = p
        if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
        let parts = s.split(separator: "/")
        if parts.count > 4 {
            return parts.prefix(1).joined(separator: "/") + "/…/" + parts.suffix(3).joined(separator: "/")
        }
        return s
    }
}

extension ScanEngine {
    nonisolated static var advisoryFloor: Int64 { 64 * 1024 * 1024 }
}
