import SwiftUI

extension Notification.Name {
    static let reclaimCheckUpdates = Notification.Name("reclaimCheckUpdates")
}

@main
struct ReclaimApp: App {
    @StateObject private var settings = Settings()

    var body: some Scene {
        WindowGroup("Reclaim") {
            RootView(settings: settings)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .reclaimCheckUpdates, object: nil)
                }
            }
        }
    }
}
