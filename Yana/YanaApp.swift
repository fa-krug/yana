import SwiftData
import SwiftUI

@main
struct YanaApp: App {
    @State private var appState = AppState()

    let container: ModelContainer = {
        do {
            let container = try ModelContainer(for: Feed.self, Tag.self, Article.self)
            Tag.ensureBuiltIns(in: container.mainContext)
            try? container.mainContext.save()
            return container
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
