import SwiftUI

extension Notification.Name {
    static let atticCheckUpdates = Notification.Name("atticCheckUpdates")
}

@main
struct AtticApp: App {
    @StateObject private var settings = Settings()

    var body: some Scene {
        WindowGroup("Attic") {
            RootView(settings: settings)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .atticCheckUpdates, object: nil)
                }
            }
        }
    }
}
