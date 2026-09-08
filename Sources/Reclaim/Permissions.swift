import Foundation
import AppKit
import SwiftUI

/// Full Disk Access is all-or-nothing on macOS. Asking once, up front, is a far
/// better experience than letting each scanner fail quietly on a protected path.
enum Permissions {

    /// TCC's own database is readable only with Full Disk Access, which makes it
    /// the standard probe. No prompt is raised by attempting it.
    static func hasFullDiskAccess() -> Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
        for p in probes {
            if FileManager.default.isReadableFile(atPath: p),
               (try? FileHandle(forReadingFrom: URL(fileURLWithPath: p)))?.closeFile() != nil {
                return true
            }
        }
        // Fall back to a folder that is protected but not TCC-owned.
        let mail = NSHomeDirectory() + "/Library/Mail"
        if FileManager.default.fileExists(atPath: mail) {
            return (try? FileManager.default.contentsOfDirectory(atPath: mail)) != nil
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Reveals the app so it can be dragged straight into the permission list.
    static func revealApp() {
        let path = Bundle.main.bundlePath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath:
            (path as NSString).deletingLastPathComponent)
    }
}

// MARK: - First-run

struct WelcomeSheet: View {
    @Binding var isPresented: Bool
    let onContinue: () -> Void
    @State private var granted = Permissions.hasFullDiskAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            VStack(alignment: .leading, spacing: DS.s3) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(DS.accent)
                Text("Let Reclaim see your disk")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text("macOS hides most of your disk from apps. Without Full Disk Access, Reclaim cannot measure your Trash, app data or device backups — and it would quietly under-report how much space you could get back.")
                    .font(DS.body())
                    .foregroundStyle(DS.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.s6)

            Divider()

            VStack(alignment: .leading, spacing: DS.s4) {
                step(1, "Open Privacy settings", "The Full Disk Access list opens directly.")
                step(2, "Switch on Reclaim", "If it is not listed, use + and choose Reclaim, or drag it in from the Finder window.")
                step(3, "Come back here", "Reclaim checks again automatically.")
            }
            .padding(DS.s6)

            Spacer()

            Divider()

            HStack(spacing: DS.s3) {
                if granted {
                    Label("Full Disk Access granted", systemImage: "checkmark.circle.fill")
                        .font(DS.body().weight(.medium))
                        .foregroundStyle(DS.safe)
                } else {
                    Button("Show Reclaim in Finder") { Permissions.revealApp() }
                        .buttonStyle(SecondaryButton())
                    Button("Open Privacy settings") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(PrimaryButton())
                }
                Spacer()
                if granted {
                    Button("Start scanning") { isPresented = false; onContinue() }
                        .buttonStyle(PrimaryButton())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue anyway") { isPresented = false; onContinue() }
                        .buttonStyle(SecondaryButton())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.s5)
        }
        .frame(width: 560, height: 480)
        .background(DS.bg)
        // Re-check when the user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            withAnimation(DS.quick) { granted = Permissions.hasFullDiskAccess() }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.s3) {
            ZStack {
                Circle().fill(DS.accentSoft)
                Text("\(n)").font(DS.mono(11, .bold)).foregroundStyle(DS.accent)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.body().weight(.medium)).foregroundStyle(DS.text)
                Text(detail).font(DS.caption()).foregroundStyle(DS.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
