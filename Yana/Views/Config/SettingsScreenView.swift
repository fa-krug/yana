import SwiftUI

/// iOS settings: a single scrolling Form. "Manage Feeds & Tags" pushes the server's own web UI;
/// every other group is a reusable section view shared with the Mac two-pane settings window.
struct SettingsScreenView: View {
    var onRestartOnboarding: () -> Void = {}
    var onShowServerNotice: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var toast: ToastMessage?

    var body: some View {
        Form {
            ServerSettingsSection()
            // Without a paired server the Manage pane has nothing to load (see
            // `MacSettingsWindow.availablePanes` for the Mac equivalent of this same guard) --
            // pass this view's own `settings` so a server change while this Form is visible is
            // observed and the row appears/disappears live, not just after a re-open.
            if AuthenticatedClient.current(settings: settings) != nil {
                manageSection
            }
            ReaderSettingsSection()
            AIModeSettingsSection()
            NotificationsSettingsSection()
            LibrarySettingsSection()
            AboutSettingsSection(
                onRestartOnboarding: {
                    onRestartOnboarding()
                    dismiss()
                },
                onShowServerNotice: {
                    onShowServerNotice()
                    dismiss()
                }
            )
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

    private var manageSection: some View {
        Section {
            NavigationLink {
                ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!)
            } label: {
                Label("Manage Feeds & Tags", systemImage: "list.bullet.rectangle")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.manage")
        } footer: {
            Text("Add, edit, and organize your feeds and tags on the server.")
        }
    }
}
