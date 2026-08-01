import Foundation

/// The iOS reader's timeline-anchor read/write logic, extracted out of `ReaderScreen` so it is
/// directly testable — there is no test harness for a SwiftUI view struct in this codebase, so
/// keeping the anchor logic inside the view meant it could only be checked by reading the code.
/// Mirrors the split `TimelineModel` already has on the Mac side (`anchorWriter` for the write path,
/// `reanchorToCurrentArticle` for the read path).
@MainActor
final class ReaderAnchorController {
    private let settings: AppSettings
    let writer: TimelineAnchorWriter

    init(settings: AppSettings, writer: TimelineAnchorWriter? = nil) {
        self.settings = settings
        self.writer = writer ?? TimelineAnchorWriter(settings: settings)
    }

    /// User-driven: persists the anchor for the article at `index` (a completed swipe).
    func saveAnchor(at index: Int, in articles: [ArticleSummary]) {
        guard articles.indices.contains(index) else { return }
        writer.record(articles[index])
    }

    /// User-driven: persists the anchor for an article opened from the article list.
    func recordOpenedArticle(_ summary: ArticleSummary) {
        writer.record(summary)
    }

    /// Keeps the displayed article selected across timeline mutations (refresh/reload/retention
    /// cleanup). Prefers the canonical UID over the per-device identifier: the UID also carries the
    /// feed, so it still resolves after a re-import that changed the article's row identity. Falls
    /// back to the identifier when the UID doesn't resolve; the two are written in lockstep by
    /// `TimelineAnchorWriter.record`. Returns `nil` when neither resolves — leave the index
    /// untouched and wait for the next delivery.
    func reanchorIndex(in articles: [ArticleSummary]) -> Int? {
        if let i = TimelineUIDIndex.index(of: settings.timelineAnchorSyncUID, in: articles) {
            settings.timelineAnchorIdentifier = articles[i].identifier
            return i
        }
        return TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: articles)
    }
}
