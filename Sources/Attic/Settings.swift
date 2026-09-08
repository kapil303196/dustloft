import Foundation
import SwiftUI

/// Persisted preferences. Seeded with hard-won defaults: Brave and every
/// cloud-synced folder are excluded out of the box, because deleting inside a
/// sync root propagates the deletion to every other device.
final class Settings: ObservableObject {

    @Published var projectRoots: [String] { didSet { save() } }
    @Published var exclusions: [String]   { didSet { save() } }
    /// Thresholds for the large-and-old sweep, adjustable from that category.
    @Published var largeFileMinMB: Int    { didSet { save() } }
    @Published var largeFileMinDays: Int  { didSet { save() } }

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
            .appendingPathComponent("Library/Application Support/Attic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private struct Blob: Codable {
        var projectRoots: [String]
        var exclusions: [String]
        var largeFileMinMB: Int?
        var largeFileMinDays: Int?
    }

    /// Moves settings and cache from the app's former name so an update does
    /// not silently reset a person's exclusions and thresholds.
    private static func migrateFromPreviousName() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support")
        let old = base.appendingPathComponent("Reclaim")
        let new = base.appendingPathComponent("Attic")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    init() {
        Settings.migrateFromPreviousName()
        let defaultRoots = [Settings.home + "/Desktop/projects"]
            .filter { FileManager.default.fileExists(atPath: $0) }

        let url = URL(fileURLWithPath: Settings.home)
            .appendingPathComponent("Library/Application Support/Attic/settings.json")

        if let d = try? Data(contentsOf: url),
           let b = try? JSONDecoder().decode(Blob.self, from: d) {
            projectRoots = b.projectRoots
            exclusions = b.exclusions
            largeFileMinMB = b.largeFileMinMB ?? 200
            largeFileMinDays = b.largeFileMinDays ?? 180
        } else {
            projectRoots = defaultRoots.isEmpty ? [Settings.home + "/Desktop"] : defaultRoots
            exclusions = Settings.defaultExclusions
            largeFileMinMB = 200
            largeFileMinDays = 180
        }
    }

    private func save() {
        let b = Blob(projectRoots: projectRoots, exclusions: exclusions,
                     largeFileMinMB: largeFileMinMB, largeFileMinDays: largeFileMinDays)
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
