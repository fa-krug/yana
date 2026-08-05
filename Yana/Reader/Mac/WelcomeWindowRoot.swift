import SwiftUI

/// Hosts the onboarding `WelcomeView` in its own Mac window. Replaces the `.fullScreenCover`'s
/// `onFinish` closure: on finish it sets the completion flag and closes the window. If the window
/// is ever restored (by Catalyst, from a previous quit) after onboarding is already done AND the
/// device is still paired, there is nothing to show, so it closes itself immediately. It must
/// NOT self-close just because `hasCompletedOnboarding` is true on its own: that's also exactly
/// `ContentView`'s re-pairing-gate precondition, which opens this same window with
/// `initialStep: .server` for a device whose session has gone invalid -- in that case the window
/// has real UI to show and must stay open.
struct WelcomeWindowRoot: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()

    var body: some View {
        WelcomeView(onFinish: {
            settings.hasCompletedOnboarding = true
            appState.showWelcome = false
            dismiss()
        }, initialStep: appState.welcomeInitialStep)
        // Match the Settings window: switches, not the AppKit checkboxes a Catalyst `Form` picks by
        // default. This window is its own SwiftUI hierarchy, so the style does not carry over.
        .toggleStyle(.switch)
        .onAppear {
            // Only self-close when there is genuinely nothing left to do: onboarding is done AND
            // the device still holds a valid session. If re-pairing is needed,
            // `AuthenticatedClient.current()` is nil, so the window correctly stays open.
            if settings.hasCompletedOnboarding, AuthenticatedClient.current() != nil {
                dismiss()
            }
        }
    }
}
