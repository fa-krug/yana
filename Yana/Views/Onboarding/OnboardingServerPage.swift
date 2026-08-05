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
                TextField("https://your-server.example.com", text: $serverURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
