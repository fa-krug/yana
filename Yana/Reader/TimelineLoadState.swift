import Foundation

/// Distinguishes "timeline not yet computed" from "genuinely empty" so the cold-start frame
/// shows a skeleton, not a wrong "No Articles" flash. `hasComputedFilter` becomes true after the
/// first `recomputeFilter()` run in `ReaderScreen`.
enum TimelineLoadState: Equatable {
    case loading
    case empty
    case loaded

    static func derive(hasComputedFilter: Bool, count: Int) -> TimelineLoadState {
        guard hasComputedFilter else { return .loading }
        return count == 0 ? .empty : .loaded
    }
}
