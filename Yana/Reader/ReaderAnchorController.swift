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

    /// Remote-apply: resolves the synced anchor UID to its index in `articles`. Deliberately never
    /// touches `writer` — so applying a remote anchor can never push and loop the write back to the
    /// device that sent it. Returns `nil` (leave the current selection untouched) when the position
    /// hasn't been restored yet, or the anchored article hasn't synced to this device yet.
    func resolveSyncedAnchorIndex(didRestoreAnchor: Bool, in articles: [ArticleSummary]) -> Int? {
        guard didRestoreAnchor,
              let i = TimelineUIDIndex.index(of: settings.timelineAnchorSyncUID, in: articles)
        else { return nil }
        settings.timelineAnchorIdentifier = articles[i].identifier
        return i
    }

    /// Keeps the displayed article selected across timeline mutations (refresh/reload/retention
    /// cleanup). Prefers the canonical synced UID over the per-device identifier: a remote anchor
    /// may have arrived for an article that hadn't synced to this device yet — the *common* case,
    /// and once that article does arrive on a later delivery, this is what finally moves the
    /// selection (`timelinePositionDidChange` won't re-fire, since the UID hasn't changed since it
    /// arrived; without this self-heal the position would only catch up on the next launch). Falls
    /// back to the identifier when the UID doesn't resolve either; the two are written in lockstep
    /// by every local write (`TimelineAnchorWriter.record`) so they only disagree in exactly this
    /// pending-sync window. Returns `nil` when neither resolves — leave the index untouched and wait
    /// for the next delivery.
    func reanchorIndex(in articles: [ArticleSummary]) -> Int? {
        if let i = TimelineUIDIndex.index(of: settings.timelineAnchorSyncUID, in: articles) {
            settings.timelineAnchorIdentifier = articles[i].identifier
            return i
        }
        return TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: articles)
    }
}
