import Foundation

/// Shared onboarding-server-step state, split out of `OnboardingServerPage` so `WelcomeView`'s
/// shared bottom footer can render the same state-driven Skip/Continue button that used to live
/// inside the page's own `Form` — it needs to sit next to the Back button (matching every other
/// step, on both iOS and Mac Catalyst) rather than floating inside the scrollable form content.
@Observable
final class OnboardingServerState {
    var isPaired = false
    var isSkipping = false
    var performPrimaryAction: () -> Void = {}

    func primaryAction() {
        performPrimaryAction()
    }
}
