import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit

/// Single shared SwiftData container, used by both the app delegate (for background
/// refresh) and the SwiftUI scene.
///
/// `ModelContainer` is `Sendable`, so the static let is safe to access from any
/// isolation domain. The main-actor bootstrap (`ensureBuiltIns` + save) runs in the
/// app delegate before any UI is shown.
enum AppContainer {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: Feed.self, Tag.self, Article.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()
}

/// Registers the background-refresh task before launch completes and schedules the first run.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private lazy var backgroundRefresh = BackgroundRefreshManager(container: AppContainer.shared)

    @MainActor
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Bootstrap built-in tags on first launch (idempotent).
        Tag.ensureBuiltIns(in: AppContainer.shared.mainContext)
        try? AppContainer.shared.mainContext.save()

        backgroundRefresh.register()
        backgroundRefresh.schedule()
        return true
    }
}

@main
struct YanaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var articleStore = ArticleStore(container: AppContainer.shared)

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .environment(articleStore)
                .task { articleStore.start() }
        }
        .modelContainer(AppContainer.shared)
    }
}
