import SwiftUI

/// The card background both onboarding pages (`OnboardingServerPage`, `OnboardingAIModePage`) wrap
/// their content sections in, factored out so a visual tweak to the onboarding card style only
/// needs to happen in one place.
func onboardingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
}
