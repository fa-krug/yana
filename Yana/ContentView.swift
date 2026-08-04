import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var appState: AppState

    @Environment(\.openWindow) private var openWindow

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
                MacRootView()
            } else {
                ReaderScreen(appState: appState)
                    .fullScreenCover(isPresented: $appState.showWelcome) {
                        WelcomeView(onFinish: {
                            settings.hasCompletedOnboarding = true
                            appState.showWelcome = false
                        })
                        .interactiveDismissDisabled()
                    }
                    .fullScreenCover(isPresented: $appState.showServerMigrationNotice) {
                        ServerMigrationNoticeView(onDismiss: {
                            settings.hasDismissedServerMigrationNotice = true
                            appState.showServerMigrationNotice = false
                        })
                        .interactiveDismissDisabled()
                    }
            }
        }
        .onAppear {
            // Test hook: force the first-launch flow regardless of persisted state.
            if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_ONBOARDING") {
                settings.hasCompletedOnboarding = false
            }
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
                    if isMac {
                        openWindow(id: WindowID.serverNotice, value: true)
                    } else {
                        appState.showServerMigrationNotice = true
                    }
                }
            }
            if !settings.hasCompletedOnboarding, !Self.skipOnboarding {
                if isMac {
                    openWindow(id: WindowID.welcome, value: true)
                } else {
                    appState.showWelcome = true
                }
            }
        }
    }
}
