import Testing
@testable import Yana

struct WelcomeGateTests {
    @Test func freshInstallNeedsWelcome() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: false, isPaired: false, hasSkippedServerPairing: false
        )
        #expect(step == .welcome)
    }

    @Test func revokedSessionNeedsServerStepEvenIfNeverSkippedBefore() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: false, hasSkippedServerPairing: false
        )
        #expect(step == .server)
    }

    @Test func deliberateSkipDoesNotReenterTheServerStep() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: false, hasSkippedServerPairing: true
        )
        #expect(step == nil)
    }

    @Test func pairedDeviceNeedsNoStep() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: true, hasSkippedServerPairing: false
        )
        #expect(step == nil)
    }

    @Test func pairedDeviceNeedsNoStepEvenIfItHadPreviouslySkipped() {
        // Defensive: once paired, hasSkippedServerPairing is expected to be cleared (Task 5), but
        // isPaired alone must already be sufficient here regardless.
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: true, hasSkippedServerPairing: true
        )
        #expect(step == nil)
    }

    @Test func pendingServerNoticeHoldsBackTheReentryToTheServerStep() {
        // The pre-migration user's shape: onboarded under the old flow, never paired. Without the
        // hold this is exactly the `.server` re-pairing case, which must wait for the notice.
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: false, hasSkippedServerPairing: false,
            isServerNoticePending: true
        )
        #expect(step == nil)
    }

    @Test func pendingServerNoticeHoldsBackFirstLaunchWelcomeToo() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: false, isPaired: false, hasSkippedServerPairing: false,
            isServerNoticePending: true
        )
        #expect(step == nil)
    }

    @Test func dismissedServerNoticeLetsTheServerStepFollow() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: false, hasSkippedServerPairing: false,
            isServerNoticePending: false
        )
        #expect(step == .server)
    }
}
