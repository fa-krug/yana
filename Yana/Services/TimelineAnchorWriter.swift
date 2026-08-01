import Foundation

/// Records the timeline anchor (both the per-device `identifier` and the canonical cross-device
/// `uid`). This is the single write path both platforms' user-driven
/// selection changes go through — iOS's `ReaderAnchorController` (backing `ReaderScreen`'s
/// `saveAnchor`/`openArticle`) and Mac's `TimelineModel` (`selection` setter/`moveSelection`) — so
/// the no-ping-pong guarantee (only a user-driven change may push) is a testable seam instead of
/// resting on "this private method never calls that other private method": tests assert against
/// `pushAnchor` here, not against a bare static call buried inside a SwiftUI view or an
/// `@Observable` model.
@MainActor
final class TimelineAnchorWriter {
    private let settings: AppSettings
    /// Injectable so tests can spy on pushes without touching the real `NSUbiquitousKeyValueStore`.
    /// Defaults to the real coalesced push in production.
    var pushAnchor: (AppSettings) -> Void

    init(settings: AppSettings, pushAnchor: @escaping (AppSettings) -> Void = { SettingsCloudSync.pushSoon($0) }) {
        self.settings = settings
        self.pushAnchor = pushAnchor
    }

    /// Records `summary` as the timeline anchor and pushes it (coalesced). Call this only from a
    /// user-driven selection change — a completed swipe, a sidebar click, Next/Previous Article, or
    /// picking an article from the list. Never call it from a remote-anchor apply path: doing so
    /// would loop the write straight back to the device that sent it, and two open devices would
    /// trade anchor writes forever.
    func record(_ summary: ArticleSummary) {
        settings.timelineAnchorIdentifier = summary.identifier
        settings.timelineAnchorSyncUID = summary.uid
        pushAnchor(settings)
    }
}
