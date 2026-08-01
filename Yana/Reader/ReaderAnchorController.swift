import Foundation

/// The iOS reader's timeline-anchor read/write logic, extracted out of `ReaderScreen` so the
/// no-ping-pong guarantee (only user-driven selection changes push) is directly testable instead of
/// resting on "this SwiftUI view's private method never calls that other private method" — there is
/// no test harness for a SwiftUI view struct in this codebase, so keeping the anchor write inside
/// the view meant the guarantee could only be asserted by reading the code. Mirrors the split
/// `TimelineModel` already has on the Mac side (`anchorWriter` for the push path,
/// `reanchorToCurrentArticle`/`jumpToSyncedTimelinePosition` for the read/remote-apply path).
@MainActor
final class ReaderAnchorController {
    private let settings: AppSettings
    let writer: TimelineAnchorWriter

    init(settings: AppSettings, writer: TimelineAnchorWriter? = nil) {
        self.settings = settings
        self.writer = writer ?? TimelineAnchorWriter(settings: settings)
    }

    /// User-driven: persists + pushes the anchor for the article at `index` (a completed swipe).
    func saveAnchor(at index: Int, in articles: [ArticleSummary]) {
        guard articles.indices.contains(index) else { return }
        writer.record(articles[index])
    }

    /// User-driven: persists + pushes the anchor for an article opened from the article list.
    func recordOpenedArticle(_ summary: ArticleSummary) {
        writer.record(summary)
    }



    /// Keeps the displayed article selected across timeline mutations (refresh/reload/retention
    /// cleanup). Returns `nil` when it doesn't resolve — leave the index untouched and wait
    /// for the next delivery.
    func reanchorIndex(in articles: [ArticleSummary]) -> Int? {
        return TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: articles)
    }
}
