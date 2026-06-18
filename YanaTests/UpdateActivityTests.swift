import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("UpdateActivity")
struct UpdateActivityTests {
    @Test func startsIdle() {
        let activity = UpdateActivity()
        #expect(activity.isUpdating == false)
    }

    @Test func tracksSingleOperation() async {
        let activity = UpdateActivity()
        activity.begin()
        #expect(activity.isUpdating == true)
        activity.end()
        #expect(activity.isUpdating == false)
    }

    @Test func staysActiveWhileAnyOperationIsInFlight() {
        let activity = UpdateActivity()
        activity.begin()
        activity.begin()
        activity.end()
        #expect(activity.isUpdating == true)
        activity.end()
        #expect(activity.isUpdating == false)
    }

    @Test func endNeverGoesNegative() {
        let activity = UpdateActivity()
        activity.end()
        #expect(activity.isUpdating == false)
        activity.begin()
        #expect(activity.isUpdating == true)
    }

    @Test func runKeepsActiveForDurationOfWork() async {
        let activity = UpdateActivity()
        let result = await activity.run {
            #expect(activity.isUpdating == true)
            return 42
        }
        #expect(result == 42)
        #expect(activity.isUpdating == false)
    }

    @Test func restartRunsTheNewOperation() async {
        let activity = UpdateActivity()
        var ran = false
        await activity.restart { ran = true }.value
        #expect(ran == true)
        #expect(activity.isUpdating == false)
    }

    @Test func restartCancelsThePreviousRun() async {
        let activity = UpdateActivity()
        var firstCancelled = false
        let first = activity.restart {
            while !Task.isCancelled { await Task.yield() }
            firstCancelled = true
        }
        let second = activity.restart {}
        await first.value
        await second.value
        #expect(firstCancelled == true)
        #expect(activity.isUpdating == false)
    }

    @Test func restartReturnsToIdleAfterTheNewRunCompletes() async {
        let activity = UpdateActivity()
        let task = activity.restart {
            #expect(activity.isUpdating == true)
        }
        await task.value
        #expect(activity.isUpdating == false)
    }
}
