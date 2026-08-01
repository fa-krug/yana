import Foundation

/// Records the timeline anchor — both the per-device `identifier` and the canonical `uid`. This is
/// the single write path both platforms' user-driven selection changes go through — iOS's
/// `ReaderAnchorController` (backing `ReaderScreen`'s `saveAnchor`/`openArticle`) and Mac's
/// `TimelineModel` (`selection` setter/`moveSelection`) — so "what counts as a position change" is
/// one testable seam instead of two bare `settings` writes buried in a SwiftUI view and an
/// `@Observable` model.
@MainActor
final class TimelineAnchorWriter {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Records `summary` as the timeline anchor. Call this only from a user-driven selection change
    /// — a completed swipe, a sidebar click, Next/Previous Article, or picking an article from the
    /// list — so a programmatic re-anchor can never be mistaken for the user moving.
    func record(_ summary: ArticleSummary) {
        settings.timelineAnchorIdentifier = summary.identifier
        settings.timelineAnchorSyncUID = summary.uid
    }
}
