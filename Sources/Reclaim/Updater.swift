import Foundation
import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer build. Deliberately does not try to
/// download and swap the app bundle underneath itself: that needs a signed
/// updater and a privileged helper to be safe. It tells you a version is out
/// and takes you to the download.
@MainActor
final class Updater: ObservableObject {

    static let repo = "kapil303196/reclaim"

    @Published var latest: String?
    @Published var checking = false
    @Published var message: String?

    var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Updater.isNewer(latest, than: current)
    }

    /// Plain semantic-version comparison; missing components count as zero.
    static func isNewer(_ a: String, than b: String) -> Bool {
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
            if !silent && !updateAvailable {
                message = "Reclaim \(current) is the latest version."
            }
        } catch {
            if !silent { message = "Could not reach GitHub: \(error.localizedDescription)" }
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
                    Text("Reclaim \(updater.latest ?? "") is available")
                        .font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    Text("You are running \(updater.current).")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                }
                Spacer()
                Button("Download") { updater.openDownloadPage() }
                    .buttonStyle(PrimaryButton())
            }
        }
    }
}
