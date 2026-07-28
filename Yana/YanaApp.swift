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
        // Install the CloudKit mirroring-event observer BEFORE any container is created. Setup
        // events fire during `ModelContainer.init` and are where container/entitlement/account
        // failures surface — an observer installed afterwards misses exactly those events.
        CloudKitSyncMonitor.shared.start()
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
                    return try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                                             configurations: config)
                }
                // DEBUG-only: on every development launch, push the SwiftData-derived schema to the
                // CloudKit *Development* environment so newly added fields exist server-side and iCloud
                // data syncs completely during development (technique: fatbobman.com). This runs to
                // completion and fully tears down its temporary CloudKit container *before* the live
                // container below is created, so the process never hosts two mirroring containers on the
                // same CloudKit container at once (doing so crashes on a signed-in device). No-op without
                // an iCloud account; compiled out of release builds.
                CloudKitSchemaInitializer.run()
                #endif
                // Native CloudKit mirroring via SwiftData's .automatic integration.
                // CloudKit model invariants (all enforced by CloudKitSchemaCompatibilityTests):
                //   - All to-many relationships are [T]? (optional): Feed.articles, Feed.tags,
                //     Tag.articles, Tag.feeds, Article.tags — required by CloudKit.
                //   - All scalar attributes have default values or are optional.
                //   - No #Unique constraints (CloudKit has no equivalent).
                let config = ModelConfiguration(cloudKitDatabase: .automatic)
                return try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
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

        // Tag bootstrap is idempotent and not needed before first paint (the Starred tag is only
        // consulted on a user star action, by the tag-filter list, and on upsert — all reached
        // well after this task runs), so move its fetch + save off the synchronous launch path.
        // Save only when an insert actually happened — no per-launch context flush.
        Task { @MainActor in
            StartupTrace.measure("Tag.ensureBuiltIns") {
                let context = AppContainer.shared.mainContext
                if Tag.ensureBuiltIns(in: context) {
                    try? context.save()
                }
            }
        }
        // Register for remote notifications so CloudKit silent pushes can wake the app.
        application.registerForRemoteNotifications()
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
    #endif

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // SwiftData+CloudKit mirroring imports remote changes automatically; nothing to pull by hand.
        completionHandler(.newData)
    }
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
                .environment(articleStore)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LibraryDedup.run(container: AppContainer.shared)
                    case .background:
                        SettingsCloudSync.push(appSettings)
                        // The timeline index cache is written on a delay (see
                        // `ArticleStore.cacheWriteDelay`); flush it before the app can be suspended
                        // so the next cold start paints from an up-to-date cache.
                        Task { await articleStore.flushCache() }
                    default:
                        break
                    }
                }
                .task {
                    StartupTrace.event("scene.task.begin")
                    articleStore.start()
                    await NativeCloudKitMigration.runIfNeeded(container: AppContainer.shared)
                    // Register the remote-change observer so dedup fires on every CloudKit merge.
                    LibraryDedup.startObserving(container: AppContainer.shared)
                    // Register the remote-change observer so @Query-backed lists (Tags, Feeds, the
                    // Mac filter bar, the feed editor's tag picker) refresh on a CloudKit merge —
                    // @Query itself never sees `.NSPersistentStoreRemoteChange`.
                    LibraryRevision.shared.startObserving()
                    Task(priority: .utility) { await LegacyCloudKitCleanup.runIfNeeded() }
                    SettingsCloudSync.start(appSettings)
                    // Convert any pre-migration articles still holding legacy HTML into native
                    // blocks, off the launch/render path. No-op once the backlog is cleared.
                    BlockMigration.run(container: AppContainer.shared)
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
            MacSettingsWindow()
                .environment(articleStore)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 720, height: 620)

        // Onboarding as its own window, replacing the `.fullScreenCover` used on iOS. `Window(id:)`
        // is `@available(iOS, unavailable)` and does not compile under Mac Catalyst (which builds
        // against the iOS SDK), so this uses the same value-based `WindowGroup` singleton pattern as
        // the Settings window above: bind `for: Bool.self` and always open/pass the constant `true`.
        WindowGroup(id: WindowID.welcome, for: Bool.self) { _ in
            WelcomeWindowRoot(appState: appState)
                .environment(articleStore)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 720, height: 640)
        #endif
    }
}
