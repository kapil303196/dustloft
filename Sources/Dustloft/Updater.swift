import Foundation
import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer build. Deliberately does not try to
/// download and swap the app bundle underneath itself: that needs a signed
/// updater and a privileged helper to be safe. It tells you a version is out
/// and takes you to the download.
@MainActor
final class Updater: ObservableObject {

    static let repo = "kapil303196/dustloft"

    @Published var latest: String?
    @Published var checking = false
    @Published var message: String?
    @Published var downloadURL: URL?
    @Published var installing = false
    @Published var installStep = ""

    var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Updater.isNewer(latest, than: current)
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
        } catch {
            if !silent { message = "Could not reach GitHub: \(error.localizedDescription)" }
        }
    }

    /// Downloads the release DMG, mounts it, replaces the installed app and
    /// relaunches. Falls back to the browser when the asset is not reachable,
    /// which is what happens while the repository is private.
    func installUpdate() async {
        guard let url = downloadURL, !installing else {
            openDownloadPage(); return
        }
        installing = true
        defer { installing = false }

        do {
            installStep = "Downloading \(latest ?? "update")…"
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                message = "The download was refused (the repository may be private). Opening the releases page instead."
                openDownloadPage()
                return
            }

            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("Dustloft-update.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)

            installStep = "Mounting…"
            let mountPoint = "/Volumes/Dustloft"
            _ = Shell.run("/usr/bin/hdiutil",
                          ["attach", dmg.path, "-nobrowse", "-quiet"], timeout: 180)
            guard FileManager.default.fileExists(atPath: mountPoint + "/Dustloft.app") else {
                message = "Could not read the downloaded disk image."
                return
            }

            installStep = "Installing…"
            // ditto preserves the signature and extended attributes; cp does not.
            let target = "/Applications/Dustloft.app"
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("Dustloft-new.app").path
            try? FileManager.default.removeItem(atPath: staged)
            _ = Shell.run("/usr/bin/ditto", [mountPoint + "/Dustloft.app", staged], timeout: 300)
            _ = Shell.run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"], timeout: 120)

            let script = "/bin/rm -rf '\(target)' && /usr/bin/ditto '\(staged)' '\(target)'"
            var res = Shell.run("/bin/sh", ["-c", script], timeout: 300)
            if !res.ok { res = Shell.runAsAdmin(script) }   // /Applications may need elevation
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
        } catch {
            message = "Update failed: \(error.localizedDescription)"
        }
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

    var body: some View {
        Card(padding: DS.s4) {
            HStack(spacing: DS.s3) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(DS.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dustloft \(updater.latest ?? "") is available")
                        .font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    Text("You are running \(updater.current).")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                }
                Spacer()
                if updater.installing {
                    HStack(spacing: DS.s2) {
                        ProgressView().controlSize(.small)
                        Text(updater.installStep).font(DS.caption()).foregroundStyle(DS.textDim)
                    }
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
