import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState

    @State private var settings = AppSettings()

    /// Suppress the first-launch welcome during UI-test / screenshot runs so it never covers the
    /// reader the tests assert against.
    private static var skipOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITEST_SKIP_ONBOARDING") || args.contains("-UITEST_SCREENSHOTS")
    }

    var body: some View {
        ReaderScreen(appState: appState)
            .fullScreenCover(isPresented: $appState.showWelcome) {
                WelcomeView(onFinish: {
                    settings.hasCompletedOnboarding = true
                    appState.showWelcome = false
                })
                .interactiveDismissDisabled()
            }
            .onAppear {
                // Test hook: force the first-launch flow regardless of persisted state.
                if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_ONBOARDING") {
                    settings.hasCompletedOnboarding = false
                }
                if !settings.hasCompletedOnboarding, !Self.skipOnboarding {
                    appState.showWelcome = true
                }
            }
    }
}
