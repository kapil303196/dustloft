import Foundation
import AppKit
import SwiftUI

/// Full Disk Access is all-or-nothing on macOS. Asking once, up front, is a far
/// better experience than letting each scanner fail quietly on a protected path.
enum Permissions {

    /// Reading TCC's own database requires Full Disk Access, which makes it the
    /// standard probe. Attempting it raises no prompt and no dialog.
    ///
    /// Important: macOS applies a newly granted Full Disk Access only to a
    /// *freshly launched* process. A running app keeps the permissions it
    /// started with, so this correctly returns false until Reclaim relaunches.
    static func hasFullDiskAccess() -> Bool {
        let tcc = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
        if (try? FileManager.default.contentsOfDirectory(atPath: tcc)) != nil { return true }

        // Secondary probes, in case TCC's layout changes between releases.
        for p in [NSHomeDirectory() + "/Library/Mail",
                  NSHomeDirectory() + "/Library/Safari"] {
            if FileManager.default.fileExists(atPath: p),
               (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    /// Quits and reopens the app so a newly granted permission takes effect.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open -n '\(path)'"]
        try? p.run()
        NSApp.terminate(nil)
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
    @State private var openedSettings = false

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
                step(3, "Relaunch Reclaim",
                     "macOS only applies Full Disk Access to a freshly launched app, so Reclaim has to restart once. This is a macOS rule, not a Reclaim one.")
            }
            .padding(DS.s6)

            Spacer()

            Divider()

            HStack(spacing: DS.s3) {
                if granted {
                    Label("Full Disk Access granted", systemImage: "checkmark.circle.fill")
                        .font(DS.body().weight(.medium))
                        .foregroundStyle(DS.safe)
                } else if openedSettings {
                    // macOS will not apply the new grant to this running process.
                    Button("Relaunch Reclaim") { Permissions.relaunch() }
                        .buttonStyle(PrimaryButton())
                    Button("Check again") {
                        withAnimation(DS.quick) { granted = Permissions.hasFullDiskAccess() }
                    }
                    .buttonStyle(SecondaryButton())
                } else {
                    Button("Show Reclaim in Finder") { Permissions.revealApp() }
                        .buttonStyle(SecondaryButton())
                    Button("Open Privacy settings") {
                        openedSettings = true
                        Permissions.openFullDiskAccessSettings()
                    }
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
