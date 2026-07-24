import SwiftUI

/// Hosts the onboarding `WelcomeView` in its own Mac window. Replaces the `.fullScreenCover`'s
/// `onFinish` closure: on finish it sets the completion flag and closes the window. If the window is
/// ever restored after onboarding is already done, it closes itself immediately.
struct WelcomeWindowRoot: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()

    var body: some View {
        WelcomeView(onFinish: {
            settings.hasCompletedOnboarding = true
            appState.showWelcome = false
            dismiss()
        })
        .onAppear {
            if settings.hasCompletedOnboarding { dismiss() }
        }
    }
}
