import SwiftUI

/// Shows the currently paired server host and lets the user re-pair against a different one.
/// Reuses `OnboardingServerPage`'s sign-in flow (the same WebView pairing `DevicePairingView`
/// drives) as a sheet — changing servers always requires signing in again, since the Bearer
/// token in Keychain is only valid against the server that issued it.
struct ServerSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var isChangingServer = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        Section {
            serverRow
            .accessibilityIdentifier("settings.server")
            .sheet(isPresented: $isChangingServer) { changeServerSheet }

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
                ServerDisconnect.disconnect(settings: settings, context: modelContext)
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

    /// The re-pair sheet. **Forked, because the two platforms disagree about what a modal is.**
    /// iOS wants a navigation stack with the dismiss control in its bar; a Mac modal is a plain
    /// panel with its buttons in a trailing row at the bottom, and no bar at all. Presenting the
    /// iOS shape on the Mac gave a bar-less sheet whose only control was an X glyph floating in a
    /// footer. It also needs an explicit size there: a Mac sheet sizes to its content, and
    /// `OnboardingServerPage` lays out inside a `GeometryReader`, which reports zero in an unsized
    /// container -- the sheet collapsed to a title and a button.
    @ViewBuilder
    private var changeServerSheet: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text("Connect to Your Server")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                // The page's own content starts 4pt below whatever precedes it, which is right
                // under the wizard's tall header and far too tight under a one-line dialog title.
                .padding(.bottom, 14)
            OnboardingServerPage(onPaired: { isChangingServer = false }, isOnboardingFlow: false)
            Divider()
            HStack {
                Spacer()
                Button("Done") { isChangingServer = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // Width only: the height comes from the content, which is what makes this read as a
        // dialog rather than a panel with a field stranded at the top of it.
        .frame(width: 520)
        #else
        NavigationStack {
            OnboardingServerPage(onPaired: { isChangingServer = false }, isOnboardingFlow: false)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { isChangingServer = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(Text("Close"))
                    }
                }
        }
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
                Button("Change…") { isChangingServer = true }
            }
        }
        #else
        Button {
            isChangingServer = true
        } label: {
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
}
