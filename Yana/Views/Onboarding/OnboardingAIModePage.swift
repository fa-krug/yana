import SwiftUI

/// Onboarding step 3: choose the AI mode. Deliberately its own small implementation rather than
/// reusing `AIModeSettingsSection` verbatim: that component is a `Section`, built to live inside a
/// `Form`/`List`, which always expands to fill whatever height it's given -- wrapping it in a
/// `Form` here left the same "sparse content, huge dead space below it" problem `OnboardingServerPage`
/// had (see its comments). It mirrors that page's layout instead, platform fork and all, so the two
/// steps read as one wizard: a stock segmented picker at its natural size on macOS, the hand-drawn
/// card row on iOS, top-aligned on the Mac and centered on iOS. The icon/title/subtitle header for
/// this step lives in `WelcomeView.header`, fixed in position across every step, not drawn here.
struct OnboardingAIModePage: View {
    @Environment(AppSettings.self) private var settings
    @State private var appleIntelligenceStatus: AppleIntelligenceAvailability?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height, alignment: contentAlignment)
            }
        }
        .accessibilityIdentifier("onboardingAIModeScreen")
        .task { appleIntelligenceStatus = AppleIntelligenceClient().availability }
    }

    /// Same fork, and same reason, as `OnboardingServerPage.contentAlignment`.
    private var contentAlignment: Alignment {
        #if os(macOS)
        .top
        #else
        .center
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI Mode")
                    .font(.subheadline.weight(.medium))
                modePicker
                Text("Server mode uses whatever AI provider you've configured on the server. Apple Intelligence runs entirely on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.aiMode == .appleIntelligence {
                statusRow
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    /// Two mutually exclusive options are a segmented control on the Mac; iOS keeps the card row,
    /// matching `OnboardingServerPage`'s own fork.
    @ViewBuilder
    private var modePicker: some View {
        let selection = Binding(get: { settings.aiMode }, set: { settings.aiMode = $0 })
        #if os(macOS)
        Picker("", selection: selection) {
            ForEach(AIMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        #else
        card {
            Picker("AI Mode", selection: selection) {
                ForEach(AIMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var statusRow: some View {
        #if os(macOS)
        LabeledContent("Status") { Text(statusText) }
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        card {
            LabeledContent("Status") { Text(statusText) }
        }
        #endif
    }

    #if !os(macOS)
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    #endif

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
        .environment(AppSettings())
}
