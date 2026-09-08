import Foundation
import SwiftUI

/// Persisted preferences. Seeded with hard-won defaults: Brave and every
/// cloud-synced folder are excluded out of the box, because deleting inside a
/// sync root propagates the deletion to every other device.
final class Settings: ObservableObject {

    @Published var projectRoots: [String] { didSet { save() } }
    @Published var exclusions: [String]   { didSet { save() } }

    private static let home = NSHomeDirectory()

    /// Never scanned, never offered, not overridable from the UI.
    static let hardExclusions: [String] = [
        home + "/Dropbox",
        home + "/Library/Mobile Documents",       // iCloud Drive
        home + "/Library/CloudStorage",           // OneDrive, Drive, Box…
        home + "/Library/Application Support/BraveSoftware",
        home + "/Library/Caches/BraveSoftware"
    ]

    static let defaultExclusions: [String] = [
        home + "/Library/Application Support/BraveSoftware",
        home + "/Library/Caches/BraveSoftware"
    ]

    private var file: URL {
        let dir = URL(fileURLWithPath: Settings.home)
            .appendingPathComponent("Library/Application Support/Reclaim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private struct Blob: Codable {
        var projectRoots: [String]
        var exclusions: [String]
    }

    init() {
        let defaultRoots = [Settings.home + "/Desktop/projects"]
            .filter { FileManager.default.fileExists(atPath: $0) }

        let url = URL(fileURLWithPath: Settings.home)
            .appendingPathComponent("Library/Application Support/Reclaim/settings.json")

        if let d = try? Data(contentsOf: url),
           let b = try? JSONDecoder().decode(Blob.self, from: d) {
            projectRoots = b.projectRoots
            exclusions = b.exclusions
        } else {
            projectRoots = defaultRoots.isEmpty ? [Settings.home + "/Desktop"] : defaultRoots
            exclusions = Settings.defaultExclusions
        }
    }

    private func save() {
        let b = Blob(projectRoots: projectRoots, exclusions: exclusions)
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: file) }
    }

    /// A path is protected if it sits inside any hard or user exclusion.
    func isExcluded(_ path: String) -> Bool {
        let all = Settings.hardExclusions + exclusions
        return all.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func isHardExcluded(_ path: String) -> Bool {
        Settings.hardExclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
