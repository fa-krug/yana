import Testing
@testable import Yana

struct TimelineLoadStateTests {
    @Test func loadingUntilFilterComputed() {
        #expect(TimelineLoadState.derive(hasComputedFilter: false, count: 0) == .loading)
        #expect(TimelineLoadState.derive(hasComputedFilter: false, count: 10) == .loading)
    }

    @Test func emptyOnlyWhenConfirmedZero() {
        #expect(TimelineLoadState.derive(hasComputedFilter: true, count: 0) == .empty)
    }

    @Test func loadedWhenArticlesPresent() {
        #expect(TimelineLoadState.derive(hasComputedFilter: true, count: 3) == .loaded)
    }
}
