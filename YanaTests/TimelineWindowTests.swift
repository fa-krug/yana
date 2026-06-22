import Testing
@testable import Yana

struct TimelineWindowTests {
    // MARK: - Database exhaustion stops growth

    @Test func doesNotExtendWhenDatabaseExhausted() {
        // Fetch returned fewer rows than the limit → no older articles exist.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 40, currentLimit: 100, index: 0
        ) == false)
    }

    @Test func doesNotExtendWhenEnoughOlderLoaded() {
        // Full page fetched and the index sits well past the oldest loaded article, so plenty of
        // older articles are already available behind it.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, index: 50, lookahead: 25
        ) == false)
    }

    // MARK: - Swipe / filter-driven growth (toward older articles)

    @Test func extendsWhenIndexApproachesOldestEnd() {
        // Reader is near the front (oldest) of the loaded list and older rows may still exist.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, index: 5, lookahead: 25
        ) == true)
    }

    @Test func boundaryExactlyAtLookaheadDoesNotExtend() {
        // index == lookahead → exactly `lookahead` older articles loaded (strict less-than).
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, index: 25, lookahead: 25
        ) == false)
    }

    @Test func extendsJustInsideLookaheadBoundary() {
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, index: 24, lookahead: 25
        ) == true)
    }

    // MARK: - nextLimit

    @Test func nextLimitAddsPageSize() {
        #expect(TimelineWindow.nextLimit(100, pageSize: 100) == 200)
        #expect(TimelineWindow.nextLimit(200, pageSize: 100) == 300)
    }
}
