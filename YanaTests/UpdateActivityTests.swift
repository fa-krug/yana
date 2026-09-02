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

    @Test func hasNoLabelWithoutAPercentage() {
        let activity = UpdateActivity()
        activity.setProgress(nil)
        #expect(activity.progressPercent == nil)
        #expect(activity.progressLabel == nil)
    }

    /// Bundle-pinned, following `PluralAgreementTests`' approach: the simulator's language is not
    /// guaranteed to be English, and `locale:` alone selects plural/number *rules*, not which
    /// `.lproj` is used, so resolution has to go through an explicit per-language bundle to be
    /// locale-independent.
    private static func bundle(_ language: String) -> Bundle? {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    private func percentString(_ value: Int, _ language: String) throws -> String {
        let bundle = try #require(Self.bundle(language), "no \(language).lproj in the app bundle")
        return String(localized: "\(value)%", bundle: bundle, locale: Locale(identifier: language))
    }

    /// Asserts the literal rendered strings, not `progressLabel` against
    /// `String(localized: "\(55)%")` -- the exact expression the implementation evaluates. That
    /// comparison would pass even if the catalog were missing the key entirely, since both sides
    /// would then render the same raw key back; it is precisely the failure this task had to guard
    /// against (the task brief's own example guessed the wrong key, `"%lld%"` instead of the
    /// actually-extracted `"%lld%%"`, and only an out-of-band check of the compiled stringsdata
    /// caught it). Resolving through explicit per-language bundles here pins both the content and
    /// the locale, so a reverted or misspelled catalog entry fails this test directly.
    @Test func rendersThePercentageVerbatim() throws {
        let activity = UpdateActivity()
        activity.setProgress(55)
        #expect(activity.progressPercent == 55)

        #expect(try percentString(0, "en") == "0%")
        #expect(try percentString(55, "en") == "55%")
        #expect(try percentString(100, "en") == "100%")

        // German puts a space before the percent sign.
        #expect(try percentString(0, "de") == "0 %")
        #expect(try percentString(55, "de") == "55 %")
        #expect(try percentString(100, "de") == "100 %")
    }
}
