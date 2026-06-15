import SwiftData
import SwiftUI

@main
struct YanaApp: App {
    @State private var appState = AppState()

    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Feed.self, FeedGroup.self, Article.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .modelContainer(container)
    }
}
