import Foundation

/// Records the timeline anchor (the per-device `identifier`) locally, and schedules a debounced
/// push of the same position to the server via `ReadingPositionSync` so every paired device
/// eventually converges on the same current article. This is the single write path both
/// platforms' user-driven selection changes go through -- iOS's `ReaderAnchorController`
/// (backing `ReaderScreen`'s `saveAnchor`/`openArticle`) and Mac's `TimelineModel` (`selection`
/// setter/`moveSelection`).
///
/// The local write is always immediate and synchronous (offline-first -- navigating never waits
/// on network); the server push is best-effort and coalesced, retried via
/// `AppSettings.pendingReadingPositionPush` if it fails. See `ReaderAnchorController` /
/// `TimelineModel`'s `jumpToSyncedTimelinePosition` for the read/remote-apply side -- it must
/// never call back into `record` here, or two open devices would trade anchor writes forever.
@MainActor
final class TimelineAnchorWriter {
    private let settings: AppSettings
    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Records `summary` as the timeline anchor locally, and schedules a debounced push to the
    /// server. Call this only from a user-driven selection change -- a completed swipe, a sidebar
    /// click, Next/Previous Article, or picking an article from the list.
    ///
    /// Also clears `AppSettings.pendingRemoteReadingPosition`: once the user has taken control of
    /// navigation, any not-yet-applied remote catch-up (a position pushed from another device,
    /// possibly still waiting on `jumpToSyncedTimelinePosition` to retry because that article
    /// hadn't synced down yet) must be abandoned rather than yanking the reader away later.
    func record(_ summary: ArticleSummary) {
        settings.timelineAnchorIdentifier = summary.identifier
        settings.timelineAnchorServerID = summary.serverID
        settings.pendingRemoteReadingPosition = nil
        ReadingPositionSync.shared.schedulePush(articleServerID: summary.serverID, settings: settings)
    }
}
