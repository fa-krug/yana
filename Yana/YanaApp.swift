import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit

/// Single shared SwiftData container, used by both the app delegate (for background
/// refresh) and the SwiftUI scene.
///
/// `ModelContainer` is `Sendable`, so the static let is safe to access from any
/// isolation domain.
enum AppContainer {
    static let shared: ModelContainer = {
        do {
            return try StartupTrace.measure("ModelContainer.init") {
                #if DEBUG
                // Screenshot-capture runs get a throwaway store in the temp directory so
                // the developer's real Mac library is never touched. The file is deleted
                // before each run so every capture starts from an empty, seed-only state.
                // This is also why ScreenshotSeed can write fixture data without risk of
                // polluting a live library.
                if MacScreenshotWindow.isRequested {
                    let storeURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("yana-screenshots.store")
                    // Remove the store file and its WAL/SHM siblings so every capture run
                    // starts from a completely clean state (SQLite leaves -wal and -shm files
                    // behind after a crash or forced-quit, and SwiftData will refuse to open
                    // if those files exist without the main store).
                    // SQLite names the siblings `<store>-wal` / `<store>-shm` — a HYPHEN suffix on
                    // the full filename, not a dot extension. `appendingPathExtension` would
                    // produce `…store.wal`, which matches nothing and leaves the real files behind.
                    for suffix in ["", "-wal", "-shm"] {
                        let sibling = storeURL.deletingLastPathComponent()
                            .appendingPathComponent(storeURL.lastPathComponent + suffix)
                        try? FileManager.default.removeItem(at: sibling)
                    }
                    let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
                    return try ModelContainer(for: Feed.self, Tag.self, Article.self,
                                             configurations: config)
                }
                #endif
                let config = ModelConfiguration()
                return try ModelContainer(for: Feed.self, Tag.self, Article.self,
                                         configurations: config)
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
        // Demo-mode banner dismissal is per-launch, not permanent — see `AppSettings.hasDismissedDemoBanner`.
        AppSettings().hasDismissedDemoBanner = false
        #if DEBUG
        // Before any seeding: a UI test that asks for a clean library must not inherit fixture data
        // left behind by an earlier test class in the same simulator container.
        UITestReset.resetIfRequested(into: AppContainer.shared.mainContext)
        DebugSeed.seedIfRequested(into: AppContainer.shared.mainContext)
        Task { @MainActor in
            await ScreenshotSeed.seedIfRequested(into: AppContainer.shared.mainContext)
        }
        #endif
        StartupTrace.event("didFinishLaunching.begin")
        // BGTaskScheduler requires registration before launch completes — keep it synchronous.
        StartupTrace.measure("backgroundRefresh.register") { backgroundRefresh.register() }
        StartupTrace.measure("backgroundRefresh.schedule") { backgroundRefresh.schedule() }

        StartupTrace.event("didFinishLaunching.end")
        return true
    }

    #if targetEnvironment(macCatalyst)
    /// Delay before the Mac's one-shot launch refresh, long enough that the window is up and first
    /// paint is done before the refresh starts.
    private static let launchRefreshDelay: Duration = .seconds(3)

    /// Run one refresh shortly after launch — but off the synchronous launch path and past first
    /// paint. The Mac isn't woken by the system for background refresh, so this keeps content fresh
    /// on open; the repeating loop armed by `schedule()` covers the rest while the app stays open.
    /// Deferring it (rather than calling `runNow()` from `didFinishLaunching`) is what keeps cold
    /// start smooth: a full `updateAll()` runs the feed fetch plus `@MainActor` upserts, and each
    /// save triggers a debounced full `ArticleStore` re-index — all of which would otherwise contend
    /// with the window's first paint.
    func scheduleLaunchRefresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchRefreshDelay)
            self?.backgroundRefresh.runNow()
        }
    }

    /// Run one refresh immediately when the window regains focus (audit U4) — the Mac's
    /// repeating loop only fires on its own interval, so a user returning to the app after a
    /// while sees stale content until the next tick without this.
    @MainActor func refreshOnFocus() { backgroundRefresh.runNow() }
    #endif

    /// Re-arm scheduling after the user changes the update interval -- on iOS the next BGTask
    /// re-schedules itself, but the Mac loop is armed once at launch and never re-read the
    /// setting (audit U4).
    @MainActor func rearmBackgroundRefresh() { backgroundRefresh.schedule() }
}

@main
struct YanaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var appSettings = AppSettings()
    @State private var articleStore = ArticleStore(container: AppContainer.shared)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .environment(appState)
                .environment(articleStore)
                .environment(appSettings)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        // The timeline index cache is written on a delay (see
                        // `ArticleStore.cacheWriteDelay`); flush it before the app can be suspended
                        // so the next cold start paints from an up-to-date cache.
                        Task { await articleStore.flushCache() }
                        // No point paying for an open SSE connection while nothing is watching it.
                        ReadingPositionLiveSync.shared.stop()
                    case .active:
                        ReadingPositionLiveSync.shared.start(settings: appSettings)
                        #if targetEnvironment(macCatalyst)
                        appDelegate.refreshOnFocus()
                        #endif
                    default:
                        break
                    }
                }
                .onChange(of: appSettings.updateInterval) { _, _ in
                    appDelegate.rearmBackgroundRefresh()
                }
                .task {
                    StartupTrace.event("scene.task.begin")
                    articleStore.start()
                    // NOTE: two one-time repair sweeps used to run here on EVERY launch -- a
                    // legacy-HTML -> blocks conversion and a duplicate-Article cleanup. Both were
                    // self-terminating fixes for bugs that no longer exist, and the dedup sweep in
                    // particular re-read the entire article table on each launch just to find
                    // nothing. Don't reintroduce a permanent launch-time sweep for a transient data
                    // fix; if one is ever needed again, gate it behind a one-shot AppSettings flag.
                    // Pull the server's article/feed state on every foreground launch. `nil` from
                    // `AuthenticatedClient` means "not paired yet" -- nothing to do, not an error.
                    // Routed through `InitialSyncGate`: on every launch after the device's first
                    // sync has ever completed, this is the same fire-and-forget, error-swallowing
                    // sync as before (a spotty connection at launch must never block first paint or
                    // crash the app); on the very first one, it blocks the reader behind
                    // `AppState.isPerformingInitialSync` until the historical backlog has landed and
                    // settled.
                    if let client = AuthenticatedClient.current() {
                        await InitialSyncGate.run(
                            container: AppContainer.shared, client: client,
                            articleStore: articleStore, appState: appState, settings: appSettings
                        )
                    }
                    // `.onChange(of: scenePhase)` below only fires on a CHANGE, so the very first
                    // `.active` state on a cold launch needs this called explicitly here too;
                    // `start()` is idempotent, so this and the scene-phase handler never race.
                    ReadingPositionLiveSync.shared.start(settings: appSettings)
                    #if targetEnvironment(macCatalyst)
                    // Kick the Mac's launch refresh now that the window is up — deferred so it
                    // doesn't contend with cold-start rendering (see `scheduleLaunchRefresh`).
                    // Skipped for screenshot capture: a real fetch would spin the toolbar
                    // progress view and can raise an error toast, both of which would land in
                    // the captured frame.
                    var skipLaunchRefresh = false
                    #if DEBUG
                    skipLaunchRefresh = MacScreenshotWindow.isRequested
                    #endif
                    if !skipLaunchRefresh { appDelegate.scheduleLaunchRefresh() }
                    #endif
                }
        }
        .modelContainer(AppContainer.shared)
        #if targetEnvironment(macCatalyst)
        // Mac menu-bar commands (article navigation, star, read-aloud, update).
        .commands { YanaCommands() }
        #endif

        #if targetEnvironment(macCatalyst)
        // The SwiftUI `Settings` scene AND the singleton `Window` scene are both macOS-only
        // (unavailable in Mac Catalyst, which compiles against the iOS SDK), so the Settings screen
        // is presented as its own `WindowGroup` instead, opened via `openWindow(id:)` (⌘, and the
        // More-menu Settings item in `MacRootView`). A plain `WindowGroup(id:)` with no `for:` value
        // opens a NEW window on every `openWindow(id:)` call — not a singleton. The documented
        // singleton path is value-based: bind `for: Bool.self` and always open/pass the same
        // constant (`true`) — SwiftUI matches on that value and refocuses the existing window
        // instead of creating a duplicate.
        WindowGroup(id: WindowID.settings, for: Bool.self) { _ in
            MacSettingsWindow(appState: appState)
                .environment(appState)
                .environment(articleStore)
                .environment(appSettings)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 720, height: 620)

        // Onboarding as its own window, replacing the `.fullScreenCover` used on iOS. `Window(id:)`
        // is `@available(iOS, unavailable)` and does not compile under Mac Catalyst (which builds
        // against the iOS SDK), so this uses the same value-based `WindowGroup` singleton pattern as
        // the Settings window above: bind `for: Bool.self` and always open/pass the constant `true`.
        WindowGroup(id: WindowID.welcome, for: Bool.self) { _ in
            WelcomeWindowRoot(appState: appState)
                .environment(appState)
                .environment(articleStore)
                .environment(appSettings)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 720, height: 640)
        // Locks the window to its content's size (which `WelcomeView` now pins to exactly this
        // size on Mac Catalyst) rather than leaving it freely resizable — onboarding is a small,
        // fixed wizard, not a document window, so there's no reason a user (or a restored prior
        // frame) should be able to stretch it into a mostly-empty giant window.
        .windowResizability(.contentSize)

        WindowGroup(id: WindowID.serverNotice, for: Bool.self) { _ in
            ServerMigrationNoticeWindowRoot(appState: appState)
                .environment(appSettings)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 680, height: 640)
        #endif
    }
}
