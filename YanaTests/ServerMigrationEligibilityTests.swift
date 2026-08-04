import Foundation
import Testing
@testable import Yana

struct ServerMigrationEligibilityTests {

    @Test func firstEvaluationOfAnExistingUserMarksThemPreServerMigration() {
        let state = ServerMigrationEligibility.evaluate(.init(), hasCompletedOnboarding: true)
        #expect(state.hasEvaluated == true)
        #expect(state.isPreServerMigrationUser == true)
    }

    @Test func firstEvaluationOfAFreshInstallDoesNotMarkThemPreServerMigration() {
        let state = ServerMigrationEligibility.evaluate(.init(), hasCompletedOnboarding: false)
        #expect(state.hasEvaluated == true)
        #expect(state.isPreServerMigrationUser == false)
    }

    @Test func secondEvaluationIsANoOpEvenIfOnboardingFinishedSince() {
        let firstPass = ServerMigrationEligibility.evaluate(.init(), hasCompletedOnboarding: false)
        #expect(firstPass.isPreServerMigrationUser == false)

        // A fresh install completes onboarding later in the same run — must not be reclassified.
        let secondPass = ServerMigrationEligibility.evaluate(firstPass, hasCompletedOnboarding: true)
        #expect(secondPass.isPreServerMigrationUser == false)
        #expect(secondPass.hasEvaluated == true)
    }

    @Test func autoShowRequiresEligibilityAndNoPriorDismissal() {
        #expect(ServerMigrationEligibility.shouldAutoShow(isPreServerMigrationUser: true, hasDismissedNotice: false) == true)
        #expect(ServerMigrationEligibility.shouldAutoShow(isPreServerMigrationUser: true, hasDismissedNotice: true) == false)
        #expect(ServerMigrationEligibility.shouldAutoShow(isPreServerMigrationUser: false, hasDismissedNotice: false) == false)
    }

    @Test func restoreRowOnlyShowsForPreServerMigrationUsers() {
        #expect(ServerMigrationEligibility.canRestore(isPreServerMigrationUser: true) == true)
        #expect(ServerMigrationEligibility.canRestore(isPreServerMigrationUser: false) == false)
    }
}
