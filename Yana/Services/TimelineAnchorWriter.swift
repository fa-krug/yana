import Foundation

/// Records the timeline anchor (the per-device `identifier`) locally.
/// This is the single write path both platforms' user-driven selection changes go through — iOS's 
/// `ReaderAnchorController` (backing `ReaderScreen`'s `saveAnchor`/`openArticle`) and Mac's 
/// `TimelineModel` (`selection` setter/`moveSelection`).
@MainActor
final class TimelineAnchorWriter {
    private let settings: AppSettings
    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Records `summary` as the timeline anchor locally. Call this only from a
    /// user-driven selection change — a completed swipe, a sidebar click, Next/Previous Article, or
    /// picking an article from the list.
    func record(_ summary: ArticleSummary) {
        settings.timelineAnchorIdentifier = summary.identifier
    }
}
