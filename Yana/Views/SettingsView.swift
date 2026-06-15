import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Feed configuration, groups, and API keys are coming next.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Yana")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
