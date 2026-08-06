import SwiftUI

/// Shows the currently paired server host and lets the user re-pair against a different one.
/// Reuses `OnboardingServerPage`'s sign-in flow (the same WebView pairing `DevicePairingView`
/// drives) as a sheet — changing servers always requires signing in again, since the Bearer
/// token in Keychain is only valid against the server that issued it.
struct ServerSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var isChangingServer = false

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
        } header: {
            Text("Server")
        } footer: {
            Text("Changing the server requires signing in again.")
        }
    }

    private var displayHost: String {
        URL(string: settings.serverBaseURL)?.host ?? settings.serverBaseURL
    }
}

#Preview {
    Form { ServerSettingsSection() }
}
