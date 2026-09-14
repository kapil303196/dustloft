import Foundation
import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer build and, unless switched off, installs
/// it without being asked: the DMG is downloaded and unpacked in the
/// background, and the copy on disk is swapped once Dustloft quits.
///
/// Never mid-session. A release ships on every merge, so quitting under
/// someone to update would happen constantly. Never with a password prompt or
/// a browser window either: when this user cannot replace the installed copy,
/// the background path does nothing and the banner's "Update now" remains.
@MainActor
final class Updater: ObservableObject {

    static let repo = "kapil303196/dustloft"
    static let autoInstallKey = "autoInstallUpdates"

    @Published var latest: String?
    @Published var checking = false
    @Published var message: String?
    @Published var downloadURL: URL?
    @Published var installing = false
    @Published var installStep = ""
    /// The version unpacked, verified and waiting for the app to quit.
    @Published private(set) var staged: String?
    @Published private(set) var staging = false

    private var stagedApp: String?
    private var stageDir: String?
    private var quitObserver: NSObjectProtocol?

    var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Updater.isNewer(latest, than: current)
    }

    /// On unless turned off.
    var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: Updater.autoInstallKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Updater.autoInstallKey)
            if newValue { Task { await stageIfPossible() } } else { discardStaged() }
        }
    }

    /// Plain semantic-version comparison; missing components count as zero.
    /// Pure, so it is deliberately not tied to the main actor.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
             .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Whether to fetch a release in the background. A build that was never
    /// stamped by CI (a local `./build.sh`, still 1.0.0) is left alone, or
    /// quitting a development copy would overwrite it with the release.
    nonisolated static func shouldStage(enabled: Bool, latest: String?, current: String,
                                        alreadyStaged: String?) -> Bool {
        guard enabled, current != "1.0.0", let latest,
              isNewer(latest, than: current) else { return false }
        guard let alreadyStaged else { return true }
        return isNewer(latest, than: alreadyStaged)
    }

    /// Replace the copy that is running: a standard account installs to
    /// ~/Applications. Anything run from a disk image or a translocated path
    /// is not a real install, so that goes to /Applications.
    nonisolated static func installTarget(running: String) -> String {
        running.hasSuffix("/Dustloft.app")
            && !running.hasPrefix("/Volumes/")
            && !running.contains("/AppTranslocation/")
            ? running : "/Applications/Dustloft.app"
    }

    /// Whether the swap can happen with nobody there to type a password: this
    /// user has to be able to delete every folder in the old copy and write the
    /// new one beside it. A copy once installed with administrator rights is
    /// owned by root, and fails the first test even inside a writable folder.
    nonisolated static func canReplaceSilently(_ target: String) -> Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: (target as NSString).deletingLastPathComponent) else { return false }
        guard fm.fileExists(atPath: target) else { return true }
        guard fm.isWritableFile(atPath: target) else { return false }
        let walk = fm.enumerator(atPath: target)
        while let rel = walk?.nextObject() as? String {
            let path = target + "/" + rel
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
               !fm.isWritableFile(atPath: path) { return false }
        }
        return true
    }

    func check(silent: Bool = false) async {
        guard !checking else { return }
        checking = true
        message = nil
        defer { checking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                // A private repository, or no release published yet.
                if !silent { message = "No published release to compare against yet." }
                return
            }
            guard http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                if !silent { message = "Could not read the release information." }
                return
            }
            latest = tag
            // Prefer the DMG asset so the app can update itself in place.
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets {
                    if let n = a["name"] as? String, n.hasSuffix(".dmg"),
                       let u = a["browser_download_url"] as? String {
                        downloadURL = URL(string: u); break
                    }
                }
            }
            if !silent && !updateAvailable {
                message = "Dustloft \(current) is the latest version."
            }
            // Not awaited: a manual check should answer now, not after a download.
            if updateAvailable { Task { await stageIfPossible() } }
        } catch {
            if !silent { message = "Could not reach GitHub: \(error.localizedDescription)" }
        }
    }

    // MARK: Background install

    /// Downloads and unpacks the release, then arranges for it to replace the
    /// installed copy when Dustloft quits. Silent throughout: any failure just
    /// leaves the banner offering the manual path.
    func stageIfPossible() async {
        guard Updater.shouldStage(enabled: autoInstall, latest: latest, current: current,
                                  alreadyStaged: staged),
              let url = downloadURL, !staging, !installing else { return }
        let target = Updater.installTarget(running: Bundle.main.bundlePath)
        guard Updater.canReplaceSilently(target) else { return }

        staging = true
        defer { staging = false }

        guard let dir = try? await download(url) else { return }
        let unpacked = await Task.detached { Updater.unpack(dmg: dir + "/Dustloft.dmg", into: dir) }.value
        try? FileManager.default.removeItem(atPath: dir + "/Dustloft.dmg")
        // Checked against what was actually unpacked, not the tag: the swap
        // must never install something older than what is running.
        guard let unpacked, Updater.isNewer(unpacked.version, than: current), autoInstall else {
            try? FileManager.default.removeItem(atPath: dir)
            return
        }

        discardStaged()
        stagedApp = unpacked.app
        stageDir = dir
        staged = unpacked.version
        let app = unpacked.app
        // Captured values rather than self: this runs while the app is being
        // torn down, and has to hand the work to a process that outlives it.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Updater.spawnSwap(app: app, target: target, dir: dir, relaunch: false)
        }
    }

    /// Installs the staged version now instead of at the next quit.
    func restartToUpdate() {
        guard let app = stagedApp, let dir = stageDir else { return }
        if let o = quitObserver { NotificationCenter.default.removeObserver(o) }
        quitObserver = nil
        Updater.spawnSwap(app: app, target: Updater.installTarget(running: Bundle.main.bundlePath),
                          dir: dir, relaunch: true)
        NSApp.terminate(nil)
    }

    private func discardStaged() {
        if let o = quitObserver { NotificationCenter.default.removeObserver(o) }
        quitObserver = nil
        if let dir = stageDir { try? FileManager.default.removeItem(atPath: dir) }
        stagedApp = nil
        stageDir = nil
        staged = nil
    }

    /// A shell that waits for this process to exit, copies the new app beside
    /// the old one and only then swaps them, so a copy that fails part-way
    /// leaves the working install exactly as it was. Paths travel as
    /// positional arguments, never spliced into the script.
    nonisolated static func spawnSwap(app: String, target: String, dir: String, relaunch: Bool) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$3.partial"
        if /usr/bin/ditto "$2" "$3.partial" && /bin/rm -rf "$3" && /bin/mv "$3.partial" "$3"; then
          /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
        fi
        /bin/rm -rf "$3.partial" "$4"
        if [ "$5" = 1 ]; then /usr/bin/open -n "$3"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "dustloft-update",
                       String(getpid()), app, target, dir, relaunch ? "1" : "0"]
        try? p.run()
    }

    private func download(_ url: URL) async throws -> String? {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dustloft-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("Dustloft.dmg"))
        return dir.path
    }

    /// Mounts the DMG at a private mount point and copies the app out of it.
    /// Not /Volumes/Dustloft: a Dustloft disk image the person already has open
    /// holds that name, the new one would mount as "Dustloft 1", and the copy
    /// would silently come from the old image. Blocking; call off the main actor.
    nonisolated static func unpack(dmg: String, into dir: String) -> (app: String, version: String)? {
        let fm = FileManager.default
        let mnt = dir + "/mnt"
        try? fm.createDirectory(atPath: mnt, withIntermediateDirectories: true)
        let attached = Shell.run("/usr/bin/hdiutil",
                                 ["attach", dmg, "-nobrowse", "-readonly", "-noautoopen",
                                  "-quiet", "-mountpoint", mnt], timeout: 180)
        defer {
            _ = Shell.run("/usr/bin/hdiutil", ["detach", mnt, "-force", "-quiet"], timeout: 120)
            try? fm.removeItem(atPath: mnt)
        }
        guard attached.ok, fm.fileExists(atPath: mnt + "/Dustloft.app") else { return nil }

        let app = dir + "/Dustloft.app"
        try? fm.removeItem(atPath: app)
        // ditto preserves the signature and extended attributes; cp does not.
        guard Shell.run("/usr/bin/ditto", [mnt + "/Dustloft.app", app], timeout: 300).ok,
              Shell.run("/usr/bin/codesign", ["--verify", "--deep", app], timeout: 120).ok,
              let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
              let version = info["CFBundleShortVersionString"] as? String
        else { return nil }
        return (app, version)
    }

    // MARK: Manual install

    /// Downloads the release DMG, replaces the installed app and relaunches.
    /// Unlike the background path this may ask for a password, because
    /// somebody clicked. Falls back to the browser when the asset is not
    /// reachable, which is what happens while the repository is private.
    func installUpdate() async {
        if staged != nil { restartToUpdate(); return }
        guard !installing, !staging else { return }
        guard let url = downloadURL else { openDownloadPage(); return }
        installing = true
        defer { installing = false }

        installStep = "Downloading \(latest ?? "update")…"
        guard let dir = try? await download(url) else {
            message = "The download was refused (the repository may be private). Opening the releases page instead."
            openDownloadPage()
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }

        installStep = "Unpacking…"
        guard let unpacked = await Task.detached(operation: {
            Updater.unpack(dmg: dir + "/Dustloft.dmg", into: dir)
        }).value else {
            message = "Could not read the downloaded disk image."
            return
        }

        installStep = "Installing…"
        let target = Updater.installTarget(running: Bundle.main.bundlePath)
        let uid = getuid(), gid = getgid()
        let res = await Task.detached { () -> Shell.Result in
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "/bin/rm -rf \(q(target)) && /usr/bin/ditto \(q(unpacked.app)) \(q(target))"
            let r = Shell.run("/bin/sh", ["-c", script], timeout: 300)
            if r.ok { return r }
            // /Applications may need elevation. Hand the new copy back to this
            // user afterwards: left owned by root, the next update and the
            // install script could not delete it without a password.
            return Shell.runAsAdmin(script + " && /usr/sbin/chown -R \(uid):\(gid) \(q(target))")
        }.value
        guard res.ok else {
            message = "Could not replace the installed app: \(res.err)"
            return
        }
        // The download never passed through a browser, but strip the
        // quarantine flag defensively so Gatekeeper cannot block the
        // relaunch of an app the user already trusted.
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target], timeout: 60)

        installStep = "Restarting…"
        Permissions.relaunch()
    }

    func openDownloadPage() {
        if let u = URL(string: "https://github.com/\(Updater.repo)/releases/latest") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Banner

struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    private var title: String {
        if let s = updater.staged { return "Dustloft \(s) is ready" }
        return "Dustloft \(updater.latest ?? "") is available"
    }

    private var detail: String {
        if updater.staged != nil { return "It installs itself the next time you quit Dustloft." }
        if updater.staging { return "Downloading in the background. Nothing to do." }
        return "You are running \(updater.current)."
    }

    var body: some View {
        Card(padding: DS.s4) {
            HStack(spacing: DS.s3) {
                Image(systemName: updater.staged != nil ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(DS.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    Text(detail).font(DS.caption()).foregroundStyle(DS.textDim)
                }
                Spacer()
                if updater.installing {
                    HStack(spacing: DS.s2) {
                        ProgressView().controlSize(.small)
                        Text(updater.installStep).font(DS.caption()).foregroundStyle(DS.textDim)
                    }
                } else if updater.staging {
                    ProgressView().controlSize(.small)
                } else if updater.staged != nil {
                    Button("Release notes") { updater.openDownloadPage() }
                        .buttonStyle(SecondaryButton())
                    Button("Restart now") { updater.restartToUpdate() }
                        .buttonStyle(PrimaryButton())
                } else {
                    Button("Release notes") { updater.openDownloadPage() }
                        .buttonStyle(SecondaryButton())
                    Button("Update now") { Task { await updater.installUpdate() } }
                        .buttonStyle(PrimaryButton())
                }
            }
        }
    }
}
