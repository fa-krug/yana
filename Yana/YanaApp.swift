import SwiftUI

@main
struct YanaApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
    }
}
