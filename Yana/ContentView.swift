import SwiftUI

/// Launch-argument automation guards, at file scope because they are read from three places that no
/// longer share a type: `ContentView`'s two platform roots, the shared `ContentRootLifecycle`
/// modifier, and the free `presentWelcomeIfNeeded(...)` below.
private enum ContentRootGates {
    /// Suppress the first-launch welcome during UI-test / screenshot runs so it never covers the
    /// reader the tests assert against.
    static var skipOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITEST_SKIP_ONBOARDING") || args.contains("-UITEST_SCREENSHOTS")
    }

    /// Automation guard for the server-migration eligibility evaluation and auto-show trigger.
    /// Beyond `skipOnboarding`'s launch arguments, the Mac App Store screenshot lane
    /// (`-UITEST_MAC_SCREENSHOTS`) runs against a developer's real `de.fa-krug.Yana` container
    /// (the Mac has no `erase_simulator` equivalent), so without this guard a Mac that already
    /// completed onboarding would get permanently classified as pre-migration and would pop the
    /// notice window mid-capture. `MacScreenshotWindow` only exists in DEBUG builds.
    static var skipServerMigrationAutomation: Bool {
        if skipOnboarding { return true }
        #if DEBUG
        return MacScreenshotWindow.isRequested
        #else
        return false
        #endif
    }
}

/// A device that never completed onboarding starts at `.welcome`; a device that completed
/// onboarding once but has no valid session any more (session revoked from another device, or
/// the user cleared the app's Keychain data) re-enters at `.server` instead. No-ops if neither
/// applies, or under the UI-test onboarding-skip launch arguments.
///
/// A free function rather than a method so both `ContentRootLifecycle` (which drives it from
/// `onAppear`/`scenePhase`/the session-invalidated notification) and the iOS root's
/// server-notice dismiss handler can call the one implementation. `openWindow` is taken as a
/// parameter because it is an `@Environment` value, unavailable outside a `View`/`ViewModifier`;
/// it is only actually used on macOS, where Welcome is a real singleton window rather than a cover.
@MainActor
private func presentWelcomeIfNeeded(
    appState: AppState, settings: AppSettings, openWindow: OpenWindowAction
) {
    guard !ContentRootGates.skipOnboarding else { return }
    guard let step = WelcomeGate.neededStep(
        hasCompletedOnboarding: settings.hasCompletedOnboarding,
        isPaired: AuthenticatedClient.current() != nil,
        hasSkippedServerPairing: settings.hasSkippedServerPairing
    ) else { return }
    appState.welcomeInitialStep = step
    #if os(macOS)
    openWindow(id: WindowID.welcome)
    #else
    appState.showWelcome = true
    #endif
}

/// Everything the two platform roots must do identically: the one-shot onboarding /
/// server-migration / initial-sync gate on appear, the re-pairing re-check when the scene returns
/// to `.active`, and the immediate re-check when the sync engine reports a revoked session.
///
/// Factored into a `ViewModifier` rather than duplicated under the `#if` in `ContentView.body`:
/// the roots themselves genuinely cannot be shared (macOS has no `.fullScreenCover`, and each
/// branch references types that only exist on its own platform), but this block is pure
/// behaviour with no platform surface in it, and silently losing one of these gates on one
/// platform is exactly the failure a copy-paste fork produces.
private struct ContentRootLifecycle: ViewModifier {
    let appState: AppState

    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Test hook: force the first-launch flow regardless of persisted state.
                if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_ONBOARDING") {
                    settings.hasCompletedOnboarding = false
                }
                #if os(macOS)
                autoSeedMacDemoLibraryIfNeeded()
                #endif
                var migrationNoticeWillShow = false
                if !ContentRootGates.skipServerMigrationAutomation {
                    // Skip the UserDefaults round-trip once evaluated — `evaluate` itself is what
                    // actually guarantees never-reclassify, this is just an optimization.
                    if !settings.hasEvaluatedServerMigrationEligibility {
                        let evaluated = ServerMigrationEligibility.evaluate(
                            .init(
                                hasEvaluated: settings.hasEvaluatedServerMigrationEligibility,
                                isPreServerMigrationUser: settings.isPreServerMigrationUser
                            ),
                            hasCompletedOnboarding: settings.hasCompletedOnboarding
                        )
                        settings.hasEvaluatedServerMigrationEligibility = evaluated.hasEvaluated
                        settings.isPreServerMigrationUser = evaluated.isPreServerMigrationUser
                    }
                    if ServerMigrationEligibility.shouldAutoShow(
                        isPreServerMigrationUser: settings.isPreServerMigrationUser,
                        hasDismissedNotice: settings.hasDismissedServerMigrationNotice
                    ) {
                        migrationNoticeWillShow = true
                        #if os(macOS)
                        openWindow(id: WindowID.serverNotice)
                        #else
                        appState.showServerMigrationNotice = true
                        #endif
                    }
                }
                // Existing users must see the migration notice before Welcome/pairing, not
                // alongside it — a pre-migration user has, by definition, completed onboarding but
                // never paired, so it would otherwise also satisfy the re-pairing condition below
                // in the same pass. `presentWelcomeIfNeeded` is re-run from the notice's dismiss
                // handler once it closes.
                if !migrationNoticeWillShow {
                    presentWelcomeIfNeeded(appState: appState, settings: settings, openWindow: openWindow)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // A session revoked while backgrounded (or while this window sat open on the Mac)
                // must re-prompt on return, not at next relaunch (audit U2).
                if phase == .active {
                    presentWelcomeIfNeeded(appState: appState, settings: settings, openWindow: openWindow)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .yanaSessionInvalidated).receive(on: RunLoop.main)
            ) { _ in
                presentWelcomeIfNeeded(appState: appState, settings: settings, openWindow: openWindow)
            }
    }

    #if os(macOS)
    /// The Mac window has no first-run "add a feed" flow of its own (feed management lives on the
    /// server), so a fresh, unpaired Mac install would otherwise render the sidebar/detail empty
    /// states before the user ever finishes onboarding. Seed the same demo library `ScreenshotSeed`
    /// provides for a deliberate "Skip for now" (see `OnboardingServerPage`) automatically, once, so
    /// the Mac window always has content to show at initial startup. Guarded exactly like
    /// `presentWelcomeIfNeeded`'s launch-arg checks so UI/screenshot tests are unaffected, and only
    /// runs before onboarding has ever completed — once a device pairs or finishes onboarding this
    /// never fires again, so it can't stomp on a real paired library that's briefly unauthenticated.
    private func autoSeedMacDemoLibraryIfNeeded() {
        guard !ContentRootGates.skipOnboarding,
              !settings.hasCompletedOnboarding,
              AuthenticatedClient.current() == nil
        else { return }
        Task { @MainActor in
            await ScreenshotSeed.seed(into: AppContainer.shared.mainContext)
            settings.hasSkippedServerPairing = true
        }
    }
    #endif
}

/// The app's root. The Mac shows a two-column window with a permanent article-list sidebar;
/// iPhone/iPad keep the full-screen swipe reader. This used to be one `body` branching at runtime
/// on `UIDevice.current.userInterfaceIdiom == .mac`; with a real macOS target the two branches no
/// longer type-check on the same platform (`MacRootView` is macOS-only, `ReaderScreen` is iOS-only,
/// and `.fullScreenCover` does not exist on macOS at all), so `body` forks at compile time and the
/// behaviour both roots share lives in `ContentRootLifecycle`.
struct ContentView: View {
    @Bindable var appState: AppState

    @Environment(\.openWindow) private var openWindow
    @Environment(ArticleStore.self) private var store
    @Environment(AppSettings.self) private var settings

    /// The first sync after pairing replaces the whole window on both platforms, not just the
    /// reader: its backlog lands page by page, and a list that keeps filling and reshuffling under
    /// the user is exactly what `InitialSyncGate` exists to hide.
    @ViewBuilder private var gatedRoot: some View {
        if appState.isLoadingDemoContent {
            InitialSyncLoadingView(
                title: "Loading Demo Content",
                message: "Preparing a few sample articles to try the app with."
            )
        } else if appState.isPerformingInitialSync {
            InitialSyncLoadingView()
        } else if appState.initialSyncFailed, !settings.hasCompletedInitialSync {
            InitialSyncFailedView { retryInitialSync() }
        } else {
            #if os(macOS)
            MacRootView(appState: appState, settings: settings)
            #else
            ReaderScreen(appState: appState)
            #endif
        }
    }

    /// Retries the blocking first-sync gate after `InitialSyncFailedView`'s "Try Again" button.
    /// No-ops if the device isn't actually paired (shouldn't happen -- this state is only reachable
    /// after a successful pairing -- but matches every other call site's nil-client handling).
    private func retryInitialSync() {
        guard let client = AuthenticatedClient.current() else { return }
        appState.initialSyncFailed = false
        Task {
            await InitialSyncGate.run(
                container: AppContainer.shared, client: client,
                articleStore: store, appState: appState, settings: settings
            )
        }
    }

    #if os(macOS)
    var body: some View {
        gatedRoot
            .modifier(ContentRootLifecycle(appState: appState))
    }
    #else
    var body: some View {
        gatedRoot
        .fullScreenCover(isPresented: $appState.showWelcome) {
            WelcomeView(onFinish: {
                settings.hasCompletedOnboarding = true
                appState.showWelcome = false
                if let client = AuthenticatedClient.current() {
                    Task {
                        await InitialSyncGate.run(
                            container: AppContainer.shared, client: client,
                            articleStore: store, appState: appState, settings: settings
                        )
                    }
                }
            }, initialStep: appState.welcomeInitialStep)
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $appState.showServerMigrationNotice) {
            ServerMigrationNoticeView(onDismiss: {
                settings.hasDismissedServerMigrationNotice = true
                appState.showServerMigrationNotice = false
                presentWelcomeIfNeeded(appState: appState, settings: settings, openWindow: openWindow)
            })
            .interactiveDismissDisabled()
        }
        .modifier(ContentRootLifecycle(appState: appState))
    }
    #endif
}
