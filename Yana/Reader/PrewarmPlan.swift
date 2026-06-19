import Foundation

/// Pure computation of which neighbor indices to prewarm around the current page, biased toward
/// the swipe direction so a one-direction burst warms first. Keeps the reader VC's prewarm logic
/// testable without a live UIPageViewController.
enum PrewarmPlan {
    enum Direction { case forward, backward, none }

    static func indices(current: Int, count: Int, radius: Int, direction: Direction) -> [Int] {
        guard count > 1, radius > 0, current >= 0, current < count else { return [] }
        let ahead = (1...radius).map { current + $0 }.filter { $0 < count }
        let behind = (1...radius).map { current - $0 }.filter { $0 >= 0 }
        switch direction {
        case .forward:  return ahead + behind
        case .backward: return behind + ahead
        case .none:
            // Interleave nearest-first when there is no travel direction.
            var result: [Int] = []
            for i in 0..<radius {
                if i < ahead.count { result.append(ahead[i]) }
                if i < behind.count { result.append(behind[i]) }
            }
            return result
        }
    }
}
