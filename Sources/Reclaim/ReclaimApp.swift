import SwiftUI

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
        }
    }
}
