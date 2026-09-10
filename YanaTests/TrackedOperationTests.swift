import Foundation
import Testing
@testable import Yana

@Suite("TrackedOperation persistence")
@MainActor
struct TrackedOperationTests {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "TrackedOperationTests.\(UUID())")!)
    }

    @Test func defaultsToNoTrackedOperations() {
        #expect(makeSettings().trackedOperations.isEmpty)
    }

    @Test func roundTripsThroughUserDefaults() {
        let settings = makeSettings()
        let reload = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                      startedAt: Date(timeIntervalSince1970: 1_000))
        let update = TrackedOperation(kind: .updateAll, id: 5,
                                      startedAt: Date(timeIntervalSince1970: 2_000))
        settings.trackedOperations = [reload, update]

        #expect(settings.trackedOperations == [reload, update])
        #expect(settings.trackedOperations.first?.kind == .reloadArticle(serverID: 100))
    }

    @Test func survivesAFreshSettingsInstanceOverTheSameDefaults() {
        let suite = "TrackedOperationTests.\(UUID())"
        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.trackedOperations = [
            TrackedOperation(kind: .updateAll, id: 7, startedAt: Date(timeIntervalSince1970: 1))
        ]

        // Standing in for a relaunch: a new AppSettings over the same stored defaults.
        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.trackedOperations.count == 1)
        #expect(second.trackedOperations.first?.id == 7)
    }

    // `id` alone is not unique: it is a job id for `.reloadArticle` and a run id for
    // `.updateAll`, drawn from two different server-side tables whose ids collide freely. A
    // future in-flight-operation monitor keyed only by `id` would confuse a run with a
    // same-numbered job, so `monitorKey` must disambiguate by kind.
    @Test func monitorKeyDisambiguatesJobAndRunIDSpaces() {
        let reload = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 5,
                                      startedAt: Date(timeIntervalSince1970: 1))
        let update = TrackedOperation(kind: .updateAll, id: 5,
                                      startedAt: Date(timeIntervalSince1970: 1))

        #expect(reload.monitorKey != update.monitorKey)
        #expect(reload.monitorKey == "job-5")
        #expect(update.monitorKey == "run-5")
    }

    // The progress indicator opens the server's web UI for the operation it stands for. A reload
    // is one job and the server has a detail page for it; a run has no page of its own there (it
    // is only visible as the jobs it enqueued), so it lands on the jobs list instead.
    @Test func serverPagePathOpensTheJobForAReloadAndTheJobsListForARun() {
        let reload = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                      startedAt: Date(timeIntervalSince1970: 1))
        let update = TrackedOperation(kind: .updateAll, id: 42,
                                      startedAt: Date(timeIntervalSince1970: 1))

        #expect(reload.serverPagePath == "/jobs/42")
        #expect(update.serverPagePath == "/jobs")
        #expect(TrackedOperation.jobsPagePath == "/jobs")
    }
}
