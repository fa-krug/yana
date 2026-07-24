import SwiftUI

/// Reddit source: enable toggle, client id/secret, user agent, credential test.
struct RedditSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var redditClientID = ""
    @State private var redditClientSecret = ""
    @State private var redditStatus: TestStatus = .idle

    var body: some View {
        Section("Reddit") {
            Toggle(isOn: $settings.redditEnabled) {
                Label("Enabled", systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.tintedIcon(.orange))
            }
            SecureField("Client ID", text: $redditClientID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientID) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientID); redditStatus = .idle
                }
            SecureField("Client Secret", text: $redditClientSecret)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientSecret) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientSecret); redditStatus = .idle
                }
            TextField("User Agent", text: $settings.redditUserAgent)
                .autocorrectionDisabled()
            CredentialTestControls(status: redditStatus,
                         disabled: redditClientID.isEmpty || redditClientSecret.isEmpty,
                         onClear: { redditStatus = .idle }) {
                CredentialTest.run({ redditStatus = $0 }) {
                    await CredentialTester.reddit(clientID: redditClientID,
                                                  clientSecret: redditClientSecret,
                                                  userAgent: settings.redditUserAgent)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        redditClientID = KeychainService.loadAPIKey(for: .redditClientID) ?? ""
        redditClientSecret = KeychainService.loadAPIKey(for: .redditClientSecret) ?? ""
    }
}
