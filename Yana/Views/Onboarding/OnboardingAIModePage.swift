import SwiftUI

/// Onboarding step 3: choose the AI mode. Reuses Task 17's `AIModeSettingsSection` verbatim — the
/// onboarding step and the Settings screen show identical content by design, so there's exactly
/// one implementation of this picker to keep correct.
struct OnboardingAIModePage: View {
    var body: some View {
        Form {
            AIModeSettingsSection()
        }
        .accessibilityIdentifier("onboardingAIModeScreen")
    }
}

#Preview {
    OnboardingAIModePage()
}
