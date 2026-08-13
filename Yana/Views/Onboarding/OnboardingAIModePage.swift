import SwiftUI

/// Onboarding step 3: choose the AI mode. Deliberately its own small implementation rather than
/// reusing `AIModeSettingsSection` verbatim: that component is a `Section`, built to live inside a
/// `Form`/`List`, which always expands to fill whatever height it's given -- wrapping it in a
/// `Form` here left the same "sparse content, huge dead space below it" problem `OnboardingServerPage`
/// had (see its comments). This mirrors that page's content-sized, card-styled, centered layout
/// instead, so every onboarding step reads consistently. The icon/title/subtitle header for this
/// step lives in `WelcomeView.header`, fixed in position across every step, not drawn here.
struct OnboardingAIModePage: View {
    @State private var settings = AppSettings()
    @State private var appleIntelligenceStatus: AppleIntelligenceAvailability?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
        .accessibilityIdentifier("onboardingAIModeScreen")
        .task { appleIntelligenceStatus = AppleIntelligenceClient().availability }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            onboardingCard {
                VStack(alignment: .leading, spacing: 16) {
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
                }
            }
            Text("Server mode uses whatever AI provider you've configured on the server. Apple Intelligence runs entirely on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
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

#Preview {
    OnboardingAIModePage()
}
