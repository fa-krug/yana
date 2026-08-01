import SwiftUI

struct ServerSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var serverStatus: TestStatus = .idle

    var body: some View {
        Section {
            TextField("Server Host URL", text: $settings.serverHostURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .disabled(serverStatus == .testing)

            CredentialTestControls(
                status: serverStatus,
                disabled: settings.serverHostURL.isEmpty,
                onClear: { serverStatus = .idle }
            ) {
                CredentialTest.run({ serverStatus = $0 }) {
                    // Simulate successful authentication
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    return nil
                }
            }

            Picker(selection: $settings.updateInterval) {
                ForEach(UpdateInterval.allCases) { interval in
                    Text(interval.localizedLabel).tag(interval)
                }
            } label: {
                Label("Background Updates", systemImage: "arrow.clockwise")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Connect to your Yana server instance.")
        }
    }
}
