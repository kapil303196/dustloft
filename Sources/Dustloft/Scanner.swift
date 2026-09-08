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

    /// A scan is expensive, so results are kept between launches and only
    /// refreshed automatically once they are properly stale. Rescan is always
    /// one click away.
    static let staleAfter: TimeInterval = 6 * 60 * 60

    var isStale: Bool {
        guard let last = lastScan else { return true }
        return Date().timeIntervalSince(last) > ScanEngine.staleAfter
    }

    var lastScanDescription: String? {
        guard let last = lastScan else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: last, relativeTo: Date())
    }

    private struct Cache: Codable {
        var date: Date
        var items: [String: [ScanItem]]
    }

    private static var cacheURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dustloft", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lastScan.json")
    }

    init(settings: Settings) {
        self.settings = settings
        loadCache()
    }

    private func loadCache() {
        guard let d = try? Data(contentsOf: ScanEngine.cacheURL),
              let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        // Anything already deleted since the last scan must not be shown again.
        var pruned: [String: [ScanItem]] = [:]
        for (k, list) in c.items {
            let alive = list.filter { item in
                switch item.action {
                case .removePath(let p), .removePathAdmin(let p), .gitGC(let p):
                    return FileManager.default.fileExists(atPath: p)
                default:
                    return true
                }
            }.map { i -> ScanItem in var x = i; x.selected = false; return x }
            if !alive.isEmpty { pruned[k] = alive }
        }
        items = pruned
        lastScan = c.date
    }

    private func saveCache() {
        let c = Cache(date: lastScan ?? Date(), items: items)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: ScanEngine.cacheURL) }
    }

    /// Anything smaller than this is noise in a disk-cleanup UI.
    nonisolated static let floor: Int64 = 8 * 1024 * 1024

    /// Most specific first. When two scanners claim overlapping paths, the more
    /// specific category keeps the path and the broader one gives it up.
    nonisolated static let categoryPrecedence: [String] = [
        "whatsapp", "messages", "iosbackups", "recordings", "vms",
        "browsers", "creative", "offlinemedia", "mail", "inappjunk",
        "leftovers", "pkgcache", "logs", "nvm", "ollama", "docker",
        "xcode", "node_modules", "build", "venv", "git",
        "trash", "downloads", "unusedapps",
        "devcache", "appcache", "appdata",
        // Deliberately last: a large file that already belongs to an app or a
        // project should be reported there, not as an anonymous big file.
        "largeold", "advisory"
    ]

    nonisolated private static func rank(_ category: String) -> Int {
        categoryPrecedence.firstIndex(of: category) ?? categoryPrecedence.count
    }

    /// Removes double counting between scanners.
    ///
    /// Two scanners legitimately reach the same bytes: the browser scanner
    /// claims `~/Library/Caches/Google/Chrome` while the generic app-cache
    /// scanner claims its parent `~/Library/Caches/Google`, and App data claims
    /// a whole app folder whose bulk is the cache In-app caches already listed.
    /// Left alone the same gigabytes are offered twice and the reclaimable
    /// total is inflated.
    ///
    /// Exact duplicates collapse to the more specific category. A broader row
    /// that contains more specific rows keeps only the bytes those rows do not
    /// already account for, and disappears when nothing is left.
    /// Categories that are a different view of bytes other categories already
    /// cover, rather than a competing claim on them. They are exempt from
    /// de-duplication and from the reclaimable total, so they can show a file
    /// that also sits inside an app or project folder without double counting.
    nonisolated static let lensCategories: Set<String> = ["largeold"]

    nonisolated static func deduplicate(_ input: [String: [ScanItem]]) -> [String: [ScanItem]] {
        struct Entry { var category: String; var item: ScanItem }
        var entries: [Entry] = []
        var lenses: [String: [ScanItem]] = [:]
        for (cat, list) in input {
            if lensCategories.contains(cat) { lenses[cat] = list; continue }
            for i in list { entries.append(Entry(category: cat, item: i)) }
        }

        // 1. Exact same path claimed twice: the more specific category wins.
        var byPath: [String: Entry] = [:]
        var passthrough: [Entry] = []          // advisories and non-path actions
        for e in entries {
            guard !e.item.isAdvisory, e.item.path.hasPrefix("/") else {
                passthrough.append(e); continue
            }
            if let existing = byPath[e.item.path] {
                if rank(e.category) < rank(existing.category) { byPath[e.item.path] = e }
            } else {
                byPath[e.item.path] = e
            }
        }

        // 2. When one row sits inside another, only the more specific category
        // survives. Reducing the outer row's size instead would leave a row
        // whose deletion silently removes another row the user did not tick —
        // rm -rf on a parent takes its children with it.
        let all = Array(byPath.values)
        var dropped = Set<String>()
        for outer in all {
            let prefix = outer.item.path.hasSuffix("/") ? outer.item.path : outer.item.path + "/"
            for inner in all where inner.item.path.hasPrefix(prefix) {
                if rank(inner.category) <= rank(outer.category) {
                    dropped.insert(outer.item.path)     // the container is broader
                } else {
                    dropped.insert(inner.item.path)     // the container is more specific
                }
            }
        }
        let result = all.filter { !dropped.contains($0.item.path) }

        var out: [String: [ScanItem]] = lenses
        for e in result + passthrough {
            out[e.category, default: []].append(e.item)
        }
        for (k, v) in out { out[k] = v.sorted { $0.bytes > $1.bytes } }
        return out
    }

    var totalSelected: Int64 {
        items.values.flatMap { $0 }.filter { $0.selected }.reduce(0) { $0 + $1.bytes }
    }
    var selectedItems: [ScanItem] {
        items.values.flatMap { $0 }.filter { $0.selected }
    }
    /// Excludes browse lenses, whose bytes are already counted elsewhere.
    var totalFound: Int64 {
        items.filter { !ScanEngine.lensCategories.contains($0.key) }
            .values.flatMap { $0 }
            .filter { !$0.isAdvisory }
            .reduce(0) { $0 + $1.bytes }
    }

    /// Removes rows that have just been cleaned, so the UI reflects reality
    /// immediately instead of waiting for another full scan.
    func removeCleaned(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        var next: [String: [ScanItem]] = [:]
        for (key, list) in items {
            let remaining = list.filter { !gone.contains($0.id) }
            if !remaining.isEmpty { next[key] = remaining }
        }
        withAnimation(DS.spring) {
            items = next
            volume = VolumeInfo.current()
        }
        saveCache()
    }

    /// Re-runs one scanner, used when a filter that only affects it changes.
    func rescan(category: String) async {
        guard !isScanning else { return }
        let s = settings
        let job: (() -> [ScanItem])?
        switch category {
        case "largeold":   job = { Scanners.largeOld(s) }
        case "downloads":  job = { Scanners.oldDownloads(s) }
        case "unusedapps": job = { Scanners.unusedApps(s) }
        default:           job = nil
        }
        guard let job else { return }

        isScanning = true
        progressText = "Rescanning…"
        let found: [ScanItem] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: job()) }
        }
        var next = items
        let kept = found.filter { $0.isAdvisory || $0.bytes >= ScanEngine.floor }
                        .sorted { $0.bytes > $1.bytes }
        if kept.isEmpty { next.removeValue(forKey: category) } else { next[category] = kept }
        withAnimation(DS.arrive) { items = ScanEngine.deduplicate(next) }
        saveCache()
        progressText = ""
        isScanning = false
    }

    /// Look up a row by id, so a sheet can render a frozen list while still
    /// reflecting live selection state.
    func item(_ id: UUID) -> ScanItem? {
        for list in items.values {
            if let hit = list.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    func setSelection(_ id: UUID, _ on: Bool) {
        for (k, list) in items {
            if let i = list.firstIndex(where: { $0.id == id }) {
                items[k]?[i].selected = on
                return
            }
        }
    }

    /// Explicit per-category "Select all". Because the user asked for this
    /// specific category by name, it selects everything in it — including
    /// permanent rows. The guardrail is the review sheet, which still demands a
    /// separate acknowledgement before anything permanent is removed.
    func selectAll(in category: String, _ on: Bool) {
        guard var list = items[category] else { return }
        for i in list.indices where !list[i].isAdvisory {
            list[i].selected = on
        }
        items[category] = list
    }

    /// The conservative bulk action offered on the Overview: only things that
    /// rebuild themselves, never anything needing judgement.
    func selectEverythingSafe() {
        for (key, var list) in items {
            for i in list.indices where !list[i].isAdvisory {
                if list[i].tier == .regenerable && list[i].autoSelectable {
                    list[i].selected = true
                }
            }
            items[key] = list
        }
    }

    func deselectEverything() {
        for (key, var list) in items {
            for i in list.indices { list[i].selected = false }
            items[key] = list
        }
    }

    /// Total of everything that rebuilds itself — the safe one-click number.
    var totalSafe: Int64 {
        items.values.flatMap { $0 }
            .filter { !$0.isAdvisory && $0.tier == .regenerable && $0.autoSelectable }
            .reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Scan

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        items = [:]
        Scanners.sawPermissionError = false
        // Check once, before touching anything. Without this the first read of
        // Desktop, Downloads or Documents makes macOS raise a separate prompt
        // for each folder, which is a miserable way to learn the app needs
        // Full Disk Access.
        permissionDenied = !Permissions.hasFullDiskAccess()

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
            ("recordings",   "screen recordings",  { Scanners.screenRecordings(s) }),
            ("creative",     "editing caches",     { Scanners.creativeCaches(s) }),
            ("vms",          "virtual machines",   { Scanners.virtualMachines(s) }),
            ("offlinemedia", "offline media",      { Scanners.offlineMedia(s) }),
            ("messages",     "Messages attachments",{ Scanners.messagesAttachments(s) }),
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
            ("inappjunk",    "in-app caches",      { Scanners.inAppJunk(s) }),
            ("appdata",      "app data",           { Scanners.appData(s) }),
            ("advisory",     "system items",       { Scanners.advisories() + Scanners.systemAdvisories() })
        ]

        // Scanners are independent and almost entirely I/O bound, so they run
        // concurrently and results stream into the UI as each one lands.
        // Concurrency is capped so a dozen parallel du calls cannot thrash the
        // disk on a spinning-rust or heavily loaded machine.
        let total = Double(jobs.count)
        var collected: [String: [ScanItem]] = [:]
        var completed = 0.0
        let maxParallel = 5

        await withTaskGroup(of: (String, [ScanItem]).self) { group in
            var next = 0

            func addTask(_ job: (String, String, () -> [ScanItem])) {
                group.addTask {
                    let found: [ScanItem] = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: job.2())
                        }
                    }
                    return (job.0, found)
                }
            }

            while next < jobs.count && next < maxParallel {
                addTask(jobs[next]); next += 1
            }

            var running = Set(jobs.prefix(next).map { $0.1 })
            progressText = "Scanning " + running.sorted().prefix(2).joined(separator: ", ") + "…"

            for await (key, found) in group {
                let kept = found
                    .filter { $0.isAdvisory || $0.bytes >= ScanEngine.floor }
                    .sorted { $0.bytes > $1.bytes }
                if !kept.isEmpty { collected[key] = kept }
                withAnimation(DS.arrive) { items = collected }

                completed += 1
                progress = completed / total

                if let label = jobs.first(where: { $0.0 == key })?.1 { running.remove(label) }
                if next < jobs.count {
                    running.insert(jobs[next].1)
                    addTask(jobs[next]); next += 1
                }
                progressText = running.isEmpty
                    ? "Finishing…"
                    : "Scanning " + running.sorted().prefix(2).joined(separator: ", ") + "…"
            }
        }

        // Overlap can only be resolved once every scanner has reported.
        collected = ScanEngine.deduplicate(collected)
        withAnimation(DS.arrive) { items = collected }

        if Scanners.sawPermissionError { permissionDenied = true }
        volume = VolumeInfo.current()
        lastScan = Date()
        saveCache()
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
        let sizes = Shell.childSizes(dir)
        return entries(of: dir).compactMap { p in
            let size = sizes[p] ?? 0
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
                // A "dist" or "build" inside a dependency is the published
                // package, not build output. Removing it breaks the library.
                if names != ["node_modules"],
                   line.contains("/node_modules/") || line.contains("/.venv/")
                    || line.contains("/site-packages/") || line.contains("/vendor/") {
                    continue
                }
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
        let sizes = Shell.childSizes(home + "/.cache")
        return entries(of: home + "/.cache").compactMap { p in
            guard !s.isExcluded(p) else { return nil }
            let size = sizes[p] ?? 0
            guard size > 0 else { return nil }
            return ScanItem(name: (p as NSString).lastPathComponent, path: p, bytes: size,
                            detail: nil, action: .removePath(p), tier: .regenerable)
        }
    }

    static func appCaches(_ s: Settings) -> [ScanItem] {
        let sizes = Shell.childSizes(home + "/Library/Caches")
        return entries(of: home + "/Library/Caches").compactMap { p in
            guard !s.isExcluded(p) else { return nil }
            let size = sizes[p] ?? 0
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

    struct OllamaModel: Equatable {
        var name: String
        var bytes: Int64
        var modified: String?
    }

    /// Pure parser for `ollama list` output, kept separate so it can be tested
    /// without ollama installed.
    static func parseOllamaList(_ text: String) -> [OllamaModel] {
        var out: [OllamaModel] = []
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 4 else { continue }
            guard let val = Double(cols[2]) else { continue }
            let unit = cols[3].uppercased()
            let mult: Double = unit.hasPrefix("TB") ? 1e12 : unit.hasPrefix("GB") ? 1e9
                             : unit.hasPrefix("MB") ? 1e6 : 1e3
            let modified = cols.count > 4 ? cols[4...].joined(separator: " ") : nil
            out.append(OllamaModel(name: cols[0], bytes: Int64(val * mult), modified: modified))
        }
        return out
    }

    static func ollama() -> [ScanItem] {
        let r = Shell.tool("ollama", ["list"], timeout: 30)
        guard r.ok else { return [] }
        return parseOllamaList(r.out).map { m in
            ScanItem(name: m.name, path: "ollama:" + m.name, bytes: m.bytes,
                     detail: m.modified.map { "last used \($0)" },
                     action: .ollamaModel(m.name), tier: .regenerable)
        }
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
        // Structured output first; the human-readable table is a fallback
        // because its column layout is not a stable interface.
        let js = Shell.tool("docker", ["system", "df", "--format", "{{json .}}"], timeout: 60)
        if js.ok, let bytes = parseDockerJSON(js.out), bytes > 0 {
            return [ScanItem(name: "Unused images, stopped containers, build cache",
                             path: "docker://prune", bytes: bytes,
                             detail: "Named volumes are never removed",
                             action: .dockerPrune, tier: .regenerable)]
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

    /// Sums the Reclaimable field from `docker system df --format "{{json .}}"`,
    /// which emits one JSON object per row.
    static func parseDockerJSON(_ text: String) -> Int64? {
        var total: Int64 = 0
        var sawRow = false
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = o["Type"] as? String,
                  let rec = o["Reclaimable"] as? String else { continue }
            guard type == "Images" || type == "Containers" || type == "Build Cache" else { continue }
            sawRow = true
            if let b = parseDockerSize(rec.split(separator: " ").map(String.init)) { total += b }
        }
        return sawRow ? total : nil
    }

    static func parseDockerSize(_ cols: [String]) -> Int64? {
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
        let sizes = Shell.childSizes(base)
        return entries(of: base).compactMap { p in
            let v = (p as NSString).lastPathComponent
            guard v != current else { return nil }   // never offer the active runtime
            let size = sizes[p] ?? 0
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

        // Time Machine local snapshots. These are a well known cause of space
        // vanishing into "System Data", so Dustloft thins them for you rather
        // than printing a command to copy.
        let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30)
        let names = snaps.out.split(separator: "\n").filter { $0.contains("com.apple") }
        if names.count > 0 {
            out.append(ScanItem(
                name: "\(names.count) local Time Machine snapshot\(names.count == 1 ? "" : "s")",
                path: "/", bytes: 0,
                detail: "Point-in-time copies macOS keeps on this disk. Thinning them frees whatever they were pinning; your Time Machine backups on external drives are untouched.",
                action: .adminShell("/usr/bin/tmutil thinlocalsnapshots / 9999999999999 4"),
                tier: .admin))
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
