import SwiftUI

/// YouTube source: enable toggle, API key, credential test.
struct YouTubeSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var youtubeKey = ""
    @State private var youtubeStatus: TestStatus = .idle

    var body: some View {
        Section("YouTube") {
            Toggle(isOn: $settings.youtubeEnabled) {
                Label("Enabled", systemImage: "play.rectangle.fill")
                    .labelStyle(.tintedIcon(.red))
            }
            SecureField("API Key", text: $youtubeKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(youtubeStatus == .testing)
                .onChange(of: youtubeKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .youtubeAPIKey); youtubeStatus = .idle
                }
            CredentialTestControls(status: youtubeStatus, disabled: youtubeKey.isEmpty,
                         onClear: { youtubeStatus = .idle }) {
                CredentialTest.run({ youtubeStatus = $0 }) {
                    await CredentialTester.youtube(apiKey: youtubeKey)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        youtubeKey = KeychainService.loadAPIKey(for: .youtubeAPIKey) ?? ""
    }
}
