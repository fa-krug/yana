import SwiftUI

/// Onboarding step 2: pair with a Yana Server. Reuses `DevicePairingView`'s WebView-based
/// sign-in flow (the same one Settings uses to re-pair) — this is just the entry point that
/// collects the server address and presents it as a sheet.
struct OnboardingServerPage: View {
    let onPaired: () -> Void

    @State private var settings = AppSettings()
    @State private var serverURLText = ""
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                // A plain `TextField` placeholder here renders link-blue, not the standard gray
                // placeholder color — iOS auto-styles a `.keyboardType(.URL)` field's placeholder
                // as a hyperlink when the placeholder text itself parses as a URL. An explicit
                // overlay sidesteps that and always renders as a normal gray placeholder.
                ZStack(alignment: .leading) {
                    if serverURLText.isEmpty {
                        Text("https://your-server.example.com")
                            .foregroundStyle(.secondary)
                    }
                    TextField("", text: $serverURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Server Address")
            } footer: {
                Text("Yana needs a Yana Server to sign in and sync your feeds.")
            }

            Section {
                Button("Sign In") { isPairing = true }
                    .disabled(URL(string: serverURLText) == nil)
            }
        }
        .accessibilityIdentifier("onboardingServerScreen")
        .onAppear { serverURLText = settings.serverBaseURL }
        .sheet(isPresented: $isPairing) {
            if let url = URL(string: serverURLText) {
                DevicePairingView(
                    serverBaseURL: url,
                    onPaired: { token in
                        settings.serverBaseURL = serverURLText
                        KeychainService.saveDeviceToken(token)
                        isPairing = false
                        onPaired()
                    },
                    onCancel: { isPairing = false }
                )
            }
        }
    }
}

#Preview {
    OnboardingServerPage(onPaired: {})
}
