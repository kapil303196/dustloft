import SwiftUI

extension Notification.Name {
    static let dustloftCheckUpdates = Notification.Name("dustloftCheckUpdates")
}

@main
struct DustloftApp: App {
    @StateObject private var settings = Settings()

    var body: some Scene {
        WindowGroup("Dustloft") {
            RootView(settings: settings)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .dustloftCheckUpdates, object: nil)
                }
            }
        }
    }
}
