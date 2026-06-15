import Foundation
import Testing
@testable import Yana

@Suite("AggregationLogic")
struct AggregationLogicTests {
    @Test func runLimitSubtractsCollectedToday() {
        #expect(AggregationLogic.runLimit(dailyLimit: 20, collectedToday: 5) == 15)
    }

    @Test func runLimitNeverNegative() {
        #expect(AggregationLogic.runLimit(dailyLimit: 10, collectedToday: 25) == 0)
    }

    @Test func intakeWindowKeepsRecentAndFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let recent = now.addingTimeInterval(-10 * 24 * 3600)   // 10 days old
        let future = now.addingTimeInterval(3600)
        #expect(AggregationLogic.isWithinIntakeWindow(recent, now: now))
        #expect(AggregationLogic.isWithinIntakeWindow(future, now: now))
    }

    @Test func intakeWindowDropsOld() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let old = now.addingTimeInterval(-61 * 24 * 3600)      // 61 days old
        #expect(AggregationLogic.isWithinIntakeWindow(old, now: now) == false)
    }
}
