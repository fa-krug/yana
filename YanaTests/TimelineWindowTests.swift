import Testing
@testable import Yana

struct TimelineWindowTests {
    // MARK: - Database exhaustion stops growth

    @Test func doesNotExtendWhenDatabaseExhausted() {
        // Fetch returned fewer rows than the limit → no older articles exist.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 40, currentLimit: 100, filteredCount: 0, index: 0
        ) == false)
    }

    @Test func doesNotExtendWhenEnoughFilteredAhead() {
        // Full page fetched, plenty of filtered articles ahead of the index.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, filteredCount: 100, index: 0
        ) == false)
    }

    // MARK: - Filter-driven growth

    @Test func extendsWhenFilterHidesMostOfWindow() {
        // Full page fetched but a harsh filter left too few visible near the top.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, filteredCount: 5, index: 0
        ) == true)
    }

    // MARK: - Swipe-driven growth

    @Test func extendsWhenIndexApproachesLoadedEnd() {
        // Reader is near the end of the loaded list and more rows may exist.
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, filteredCount: 100, index: 90,
            lookahead: 25
        ) == true)
    }

    @Test func boundaryExactlyAtLookaheadDoesNotExtend() {
        // filteredCount == index + lookahead → still satisfied (strict less-than).
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, filteredCount: 100, index: 75,
            lookahead: 25
        ) == false)
    }

    @Test func extendsJustPastLookaheadBoundary() {
        #expect(TimelineWindow.shouldExtend(
            loadedRawCount: 100, currentLimit: 100, filteredCount: 100, index: 76,
            lookahead: 25
        ) == true)
    }

    // MARK: - nextLimit

    @Test func nextLimitAddsPageSize() {
        #expect(TimelineWindow.nextLimit(100, pageSize: 100) == 200)
        #expect(TimelineWindow.nextLimit(200, pageSize: 100) == 300)
    }
}
