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
            .accessibilityIdentifier("settings.server")
            .sheet(isPresented: $isChangingServer) {
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
            }

            if isPaired {
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text("Remove Server Connection")
                }
                .accessibilityIdentifier("settings.removeServerConnection")
            }
        } header: {
            Text("Server")
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
