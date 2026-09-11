import SwiftUI

extension Notification.Name {
    static let dustloftCheckUpdates = Notification.Name("dustloftCheckUpdates")
}

@main
struct DustloftApp: App {
    @StateObject private var settings = Settings()
    @StateObject private var metrics = Metrics()

    var body: some Scene {
        WindowGroup("Dustloft") {
            RootView(settings: settings, metrics: metrics)
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
