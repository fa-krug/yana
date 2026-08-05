import SwiftUI

/// Picker between the two AI summarization modes (`AIMode.server` / `.appleIntelligence`). Replaces
/// the deleted 6-provider `AIProviderSettingsSection`: the server now owns whichever provider it is
/// configured with, so the device only ever chooses between "ask the server" and "run on this
/// device." When Apple Intelligence is selected, shows the live on-device availability so the user
/// understands why the "Summarize" action might still be unavailable.
struct AIModeSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var appleIntelligenceStatus: AppleIntelligenceAvailability?

    var body: some View {
        Section {
            Picker("AI Mode", selection: Binding(
                get: { settings.aiMode },
                set: { settings.aiMode = $0 }
            )) {
                ForEach(AIMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if settings.aiMode == .appleIntelligence {
                LabeledContent("Status") {
                    Text(statusText)
                }
            }
        } footer: {
            Text("Server mode uses whatever AI provider you've configured on the server. Apple Intelligence runs entirely on this device.")
        }
        .task { appleIntelligenceStatus = AppleIntelligenceClient().availability }
    }

    private var statusText: String {
        switch appleIntelligenceStatus {
        case .available: String(localized: "Available")
        case .deviceNotEligible: String(localized: "Device Not Eligible")
        case .notEnabled: String(localized: "Not Enabled")
        case .modelNotReady: String(localized: "Model Not Ready")
        case nil: String(localized: "Checking…")
        }
    }
}
