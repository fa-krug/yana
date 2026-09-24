import SwiftUI

/// Shows the currently paired server host and lets the user re-pair against a different one.
/// "Change…" hands off to the host (`onChangeServer`), which reopens the welcome flow on its
/// server step, so setting a server always goes through the same screen as onboarding rather than
/// a separate sheet. Changing servers always requires signing in again, since the Bearer token in
/// Keychain is only valid against the server that issued it.
struct ServerSettingsSection: View {
    /// Opens `WelcomeView` at `.server`. A callback rather than done here, because the two hosts
    /// present it differently: iOS has to dismiss its Settings sheet first and then raise the
    /// full-screen cover, the Mac opens the welcome window.
    var onChangeServer: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(ArticleStore.self) private var articleStore
    @State private var isConfirmingRemoval = false

    var body: some View {
        Section {
            serverRow
            .accessibilityIdentifier("settings.server")

            if isPaired {
                removeRow
                    .accessibilityIdentifier("settings.removeServerConnection")
            }
        } header: {
            sectionHeader
        } footer: {
            Text("Changing the server requires signing in again.")
        }
        .alert(
            String(localized: "Remove Server Connection?"),
            isPresented: $isConfirmingRemoval
        ) {
            Button(String(localized: "Remove Server Connection"), role: .destructive) {
                ServerDisconnect.disconnect(settings: settings, context: modelContext,
                                            appState: appState, articleStore: articleStore)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This deletes all articles stored on this device and switches to demo content until you pair a server again.")
        }
    }

    /// The Mac Settings window already names this group -- in the sidebar for the panes that own a
    /// whole page, and in the row's own label for the server row -- so repeating it as a section
    /// header just printed the same word twice. iOS has no such sidebar: the header is the only
    /// thing naming the group there, so it stays.
    @ViewBuilder
    private var sectionHeader: some View {
        #if os(macOS)
        EmptyView()
        #else
        Text("Server")
        #endif
    }

    /// A whole tappable row is the iOS idiom; on the Mac the row is a label with its value, and
    /// the action is a push button beside it. Rendering the iOS version inside a grouped macOS
    /// form drew the entire row as one filled button, which is what made this pane look like a
    /// stack of grey slabs.
    @ViewBuilder
    private var serverRow: some View {
        #if os(macOS)
        LabeledContent("Server") {
            HStack(spacing: 8) {
                Text(displayHost)
                    .foregroundStyle(.secondary)
                Button("Change…", action: onChangeServer)
            }
        }
        #else
        Button(action: onChangeServer) {
            HStack {
                Label("Server", systemImage: "server.rack")
                    .labelStyle(.tintedIcon(.green))
                Spacer()
                Text(displayHost)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    /// Same split: a full-width destructive row on iOS, a push button at its natural width on the
    /// Mac. `.bordered` plus a red tint is how System Settings draws a destructive action there --
    /// `role: .destructive` alone colours nothing on a macOS push button.
    @ViewBuilder
    private var removeRow: some View {
        #if os(macOS)
        HStack {
            Button("Remove Server Connection") { isConfirmingRemoval = true }
                .buttonStyle(.bordered)
                .tint(.red)
            Spacer()
        }
        #else
        Button(role: .destructive) {
            isConfirmingRemoval = true
        } label: {
            Text("Remove Server Connection")
        }
        #endif
    }

    private var isPaired: Bool {
        AuthenticatedClient.current(settings: settings) != nil
    }

    private var displayHost: String {
        URL(string: settings.serverBaseURL)?.host ?? settings.serverBaseURL
    }
}

#Preview {
    Form { ServerSettingsSection() }
        .environment(AppSettings())
        .environment(AppState())
        .environment(ArticleStore(container: AppContainer.shared))
}
