import SwiftUI

struct ContentView: View {
    var appState: AppState

    @State private var settings = AppSettings()
    @State private var showWelcome = false

    /// Suppress the first-launch welcome during UI-test / screenshot runs so it never covers the
    /// reader the tests assert against.
    private static var skipOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITEST_SKIP_ONBOARDING") || args.contains("-UITEST_SCREENSHOTS")
    }

    var body: some View {
        ReaderScreen(appState: appState)
            .fullScreenCover(isPresented: $showWelcome) {
                WelcomeView { showWelcome = false }
                    .interactiveDismissDisabled()
            }
            .onAppear {
                if !settings.hasCompletedOnboarding, !Self.skipOnboarding {
                    showWelcome = true
                    settings.hasCompletedOnboarding = true
                }
            }
    }
}
