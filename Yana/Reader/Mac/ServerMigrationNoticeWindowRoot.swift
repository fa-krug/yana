import SwiftUI

/// Hosts `ServerMigrationNoticeView` in its own Mac window, mirroring `WelcomeWindowRoot`. If the
/// window is restored after the notice has already been dismissed (Mac Catalyst can restore
/// windows left open at last quit), it closes itself immediately.
struct ServerMigrationNoticeWindowRoot: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var settings = AppSettings()

    var body: some View {
        ServerMigrationNoticeView(onDismiss: {
            settings.hasDismissedServerMigrationNotice = true
            dismiss()
            // Mirrors `ContentView.presentWelcomeIfNeeded()` — the notice must fully close before
            // Welcome/pairing opens, not alongside it.
            if let step = WelcomeGate.neededStep(
                hasCompletedOnboarding: settings.hasCompletedOnboarding,
                isPaired: AuthenticatedClient.current() != nil
            ) {
                appState.welcomeInitialStep = step
                openWindow(id: WindowID.welcome, value: true)
            }
        })
        .toggleStyle(.switch)
        .onAppear {
            if settings.hasDismissedServerMigrationNotice { dismiss() }
        }
    }
}
