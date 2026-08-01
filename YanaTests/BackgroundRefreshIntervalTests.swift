import Testing
import SwiftData
@testable import Yana

@MainActor
struct BackgroundRefreshIntervalTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func offMeansNoScheduling() throws {
        let c = try container()
        var scheduled = false
        // isDisabled provider returns true → schedule() must early-return before submitting.
        let mgr = BackgroundRefreshManager(
            container: c,
            secondsProvider: { nil },              // .off → nil seconds
            now: { .init(timeIntervalSince1970: 0) },
            onScheduleAttempt: { scheduled = true } // test seam, see Step 3
        )
        mgr.schedule()
        #expect(scheduled == false)
    }

    @Test func nextBeginUsesProvidedSeconds() {
        let begin = BackgroundRefreshManager.nextBeginDate(
            from: .init(timeIntervalSince1970: 0), interval: 3600)
        #expect(begin == .init(timeIntervalSince1970: 3600))
    }
}
