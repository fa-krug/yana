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
            }
        }
        .onAppear {
            // Test hook: force the first-launch flow regardless of persisted state.
            if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_ONBOARDING") {
                settings.hasCompletedOnboarding = false
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
