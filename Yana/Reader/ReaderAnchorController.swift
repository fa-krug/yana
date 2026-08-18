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
        return TimelinePageIndex.index(
            of: settings.timelineAnchorIdentifier, serverID: settings.timelineAnchorServerID, in: articles
        )
    }

    /// Applies a reading position pulled from another paired device (see
    /// `AppSettings.pendingRemoteReadingPosition`), if it resolves against `articles`. Consumes the
    /// pending value only on success -- when the target article hasn't synced down to this device
    /// yet, the value is left in place so a later call (once more of the timeline has landed) can
    /// resolve it instead of losing the position forever. It's still bounded: any user-driven
    /// navigation (`TimelineAnchorWriter.record`) clears the pending value outright, so an
    /// unresolvable/stale position doesn't linger past the point the user has taken over.
    ///
    /// Deliberately does NOT go through `writer.record`: this is the read side of the sync, and
    /// pushing the value straight back would let two open devices trade anchor writes forever. It
    /// updates `timelineAnchorIdentifier` directly instead, so subsequent self-heal reanchoring
    /// (`reanchorIndex`) still resolves to the right article without re-triggering a push.
    func jumpToSyncedTimelinePosition(in articles: [ArticleSummary]) -> Int? {
        guard let articleID = settings.pendingRemoteReadingPosition else { return nil }
        guard let index = articles.firstIndex(where: { $0.serverID == articleID }) else { return nil }
        settings.pendingRemoteReadingPosition = nil
        settings.timelineAnchorIdentifier = articles[index].identifier
        settings.timelineAnchorServerID = articleID
        return index
    }
}
