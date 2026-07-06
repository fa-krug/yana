import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit

/// Single shared SwiftData container, used by both the app delegate (for background
/// refresh) and the SwiftUI scene.
///
/// `ModelContainer` is `Sendable`, so the static let is safe to access from any
/// isolation domain. The tag bootstrap (`ensureBuiltIns` + conditional save) runs in a
/// post-launch main-actor task so it does not block `didFinishLaunchingWithOptions`.
enum AppContainer {
    static let shared: ModelContainer = {
        do {
            return try StartupTrace.measure("ModelContainer.init") {
                try ModelContainer(for: Feed.self, Tag.self, Article.self)
            }
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
        #if DEBUG
        DebugSeed.seedIfRequested(into: AppContainer.shared.mainContext)
        Task { @MainActor in
            await ScreenshotSeed.seedIfRequested(into: AppContainer.shared.mainContext)
        }
        Task { @MainActor in
            await ScreenshotFixtureCollector.collectIfRequested()
        }
        #endif
        StartupTrace.event("didFinishLaunching.begin")
        // BGTaskScheduler requires registration before launch completes — keep it synchronous.
        StartupTrace.measure("backgroundRefresh.register") { backgroundRefresh.register() }
        StartupTrace.measure("backgroundRefresh.schedule") { backgroundRefresh.schedule() }

        // Tag bootstrap is idempotent and not needed before first paint (the Starred tag is only
        // consulted on a user star action, by the tag-filter list, and on upsert — all reached
        // well after this task runs), so move its fetch + save off the synchronous launch path.
        // Save only when an insert actually happened — no per-launch context flush.
        Task { @MainActor in
            await StartupTrace.measure("Tag.ensureBuiltIns") {
                let context = AppContainer.shared.mainContext
                if Tag.ensureBuiltIns(in: context) {
                    try? context.save()
                }
            }
        }
        StartupTrace.event("didFinishLaunching.end")
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
                .task {
                    StartupTrace.event("scene.task.begin")
                    articleStore.start()
                    // Convert any pre-migration articles still holding legacy HTML into native
                    // blocks, off the launch/render path. No-op once the backlog is cleared.
                    BlockMigration.run(container: AppContainer.shared)
                }
        }
        .modelContainer(AppContainer.shared)
    }
}
