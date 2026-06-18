import Testing
@testable import Yana

@MainActor
@Suite("SyncFailureSummary")
struct SyncFailureSummaryTests {
    @Test func noFailuresReturnsNil() {
        #expect(SyncFailureSummary.message(for: []) == nil)
    }

    @Test func singleFailureNamesFeedAndMessage() {
        let feedName = "Heise"
        let message = "boom"
        let failure = AggregationService.FeedFailure(feedName: feedName, message: message)
        #expect(SyncFailureSummary.message(for: [failure])
                == String(localized: "Couldn't update \u{201C}\(feedName)\u{201D}: \(message)"))
    }

    @Test func multipleFailuresReturnCount() {
        let failures = [
            AggregationService.FeedFailure(feedName: "A", message: "x"),
            AggregationService.FeedFailure(feedName: "B", message: "y"),
        ]
        let count = failures.count
        #expect(SyncFailureSummary.message(for: failures)
                == String(localized: "\(count) feeds couldn't be updated. Check Feeds in the Library."))
    }
}
