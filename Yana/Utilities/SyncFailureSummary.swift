import Foundation

/// Builds a single user-facing summary line for a batch of failed feed updates.
enum SyncFailureSummary {
    static func message(for failures: [AggregationService.FeedFailure]) -> String? {
        switch failures.count {
        case 0:
            return nil
        case 1:
            let failure = failures[0]
            return String(localized: "Couldn't update \u{201C}\(failure.feedName)\u{201D}: \(failure.message)")
        default:
            return String(localized: "\(failures.count) feeds couldn't be updated. Check Feeds in the Library.")
        }
    }
}
