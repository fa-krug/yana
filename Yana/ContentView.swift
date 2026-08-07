import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var appState: AppState

    @Environment(\.openWindow) private var openWindow
    @Environment(ArticleStore.self) private var store

    @State private var settings = AppSettings()

    /// Suppress the first-launch welcome during UI-test / screenshot runs so it never covers the
    /// reader the tests assert against.
    private static var skipOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITEST_SKIP_ONBOARDING") || args.contains("-UITEST_SCREENSHOTS")
    }

    /// Automation guard for the server-migration eligibility evaluation and auto-show trigger.
    /// Beyond `skipOnboarding`'s launch arguments, the Mac App Store screenshot lane
    /// (`-UITEST_MAC_SCREENSHOTS`) runs against a developer's real `de.fa-krug.Yana` container
    /// (Catalyst has no `erase_simulator` equivalent), so without this guard a Mac that already
    /// completed onboarding would get permanently classified as pre-migration and would pop the
    /// notice window mid-capture. `MacScreenshotWindow` only exists in DEBUG builds.
    private static var skipServerMigrationAutomation: Bool {
        if skipOnboarding { return true }
        #if DEBUG
        return MacScreenshotWindow.isRequested
        #else
        return false
        #endif
    }

    /// The Mac (Mac Catalyst) build shows a two-column window with a permanent article-list sidebar;
    /// iPhone/iPad keep the full-screen swipe reader. `WelcomeView` (onboarding) is presented by
    /// whichever root is active.
    private var isMac: Bool { UIDevice.current.userInterfaceIdiom == .mac }

    var body: some View {
        Group {
            if isMac {
                MacRootView(appState: appState)
            } else if appState.isPerformingInitialSync {
                InitialSyncLoadingView()
            } else {
                ReaderScreen(appState: appState)
            }
        }
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
                presentWelcomeIfNeeded()
            })
            .interactiveDismissDisabled()
        }
        .onAppear {
            // Test hook: force the first-launch flow regardless of persisted state.
            if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_ONBOARDING") {
                settings.hasCompletedOnboarding = false
            }
            autoSeedMacDemoLibraryIfNeeded()
            var migrationNoticeWillShow = false
            if !Self.skipServerMigrationAutomation {
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
                    if isMac {
                        openWindow(id: WindowID.serverNotice, value: true)
                    } else {
                        appState.showServerMigrationNotice = true
                    }
                }
            }
            // Existing users must see the migration notice before Welcome/pairing, not alongside
            // it — a pre-migration user has, by definition, completed onboarding but never paired,
            // so it would otherwise also satisfy the re-pairing condition below in the same pass.
            // `presentWelcomeIfNeeded` is re-run from the notice's dismiss handler once it closes.
            if !migrationNoticeWillShow {
                presentWelcomeIfNeeded()
            }
        }
    }

    /// The Mac window has no first-run "add a feed" flow of its own (feed management lives on the
    /// server), so a fresh, unpaired Mac install would otherwise render the sidebar/detail empty
    /// states before the user ever finishes onboarding. Seed the same demo library `ScreenshotSeed`
    /// provides for a deliberate "Skip for now" (see `OnboardingServerPage`) automatically, once, so
    /// the Mac window always has content to show at initial startup. Guarded exactly like
    /// `presentWelcomeIfNeeded`'s launch-arg checks so UI/screenshot tests are unaffected, and only
    /// runs before onboarding has ever completed — once a device pairs or finishes onboarding this
    /// never fires again, so it can't stomp on a real paired library that's briefly unauthenticated.
    private func autoSeedMacDemoLibraryIfNeeded() {
        guard isMac, !Self.skipOnboarding,
              !settings.hasCompletedOnboarding,
              AuthenticatedClient.current() == nil
        else { return }
        Task { @MainActor in
            await ScreenshotSeed.seed(into: AppContainer.shared.mainContext)
            settings.hasSkippedServerPairing = true
        }
    }

    /// A device that never completed onboarding starts at `.welcome`; a device that completed
    /// onboarding once but has no valid session any more (session revoked from another device, or
    /// the user cleared the app's Keychain data) re-enters at `.server` instead. No-ops if neither
    /// applies, or under the UI-test onboarding-skip launch arguments.
    private func presentWelcomeIfNeeded() {
        guard !Self.skipOnboarding else { return }
        guard let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: settings.hasCompletedOnboarding,
            isPaired: AuthenticatedClient.current() != nil,
            hasSkippedServerPairing: settings.hasSkippedServerPairing
        ) else { return }
        appState.welcomeInitialStep = step
        if isMac {
            openWindow(id: WindowID.welcome, value: true)
        } else {
            appState.showWelcome = true
        }
    }
}
