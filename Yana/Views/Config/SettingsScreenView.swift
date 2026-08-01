import SwiftUI

/// iOS settings: a single scrolling Form. Feeds/Tags push detail screens; every other group is a
/// reusable section view shared with the Mac two-pane settings window.
struct SettingsScreenView: View {
    var onRestartOnboarding: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()
    @State private var toast: ToastMessage?
    /// Set by `onRevealDiagnostics` the moment the version row's five-tap gesture unlocks
    /// diagnostics. `AboutSettingsSection` flips `diagnosticsUnlocked` on its *own* `AppSettings`
    /// instance, so this view's separate instance is never told to re-observe that change — only a
    /// mutation to this view's own `@State` is guaranteed to trigger a re-render here. Gating on
    /// this in addition to `settings.diagnosticsUnlocked` makes the reveal take effect immediately
    /// by construction, not by relying on the toast assignment happening to re-render the body.
    @State private var diagnosticsRevealed = false
    /// Drives the Diagnostics push explicitly rather than letting a `NavigationLink` own it.
    ///
    /// "Hide Diagnostics" is tapped *inside* the pushed screen and clears both gate flags — which
    /// removes the enclosing `Section`, and with it a `NavigationLink` whose destination is on screen.
    /// SwiftUI usually pops in that situation, but that is not a contract, and the failure mode
    /// (a stranded detail view, or a re-entrant navigation warning) is exactly the kind that shows up
    /// on one OS version only. Owning the flag lets the hide handler pop *first*, then clear the
    /// gates — symmetric with the Mac branch, which already sets `selection = .about` explicitly.
    @State private var showingDiagnostics = false

    var body: some View {
        Form {
            AIProviderSettingsSection()
            ServerSettingsSection()

            if DiagnosticsReveal.isDiagnosticsVisible(
                unlocked: settings.diagnosticsUnlocked,
                revealed: diagnosticsRevealed
            ) {
                diagnosticsSection
            }
        }
        // Attached to the Form, *outside* the conditional section, so the destination survives the
        // section disappearing.
        .navigationDestination(isPresented: $showingDiagnostics) {
            SyncLogView(onHideDiagnostics: {
                showingDiagnostics = false
                settings.diagnosticsUnlocked = false
                diagnosticsRevealed = false
            })
        }
        // Keep the toggle control on the trailing edge (matching the row pickers). On Mac Catalyst
        // the default form Toggle is a leading checkbox, which sits before the row's tinted icon and
        // looks misaligned; a switch matches iOS (its default) and the trailing pickers.
        .toggleStyle(.switch)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
        }
        .toast($toast)
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                showingDiagnostics = true
            } label: {
                HStack {
                    Label("Diagnostics", systemImage: "stethoscope")
                        .labelStyle(.tintedIcon(.teal))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.diagnostics")
        } footer: {
            Text("Shows this launch's iCloud sync activity, for troubleshooting and bug reports.")
        }
    }

}
