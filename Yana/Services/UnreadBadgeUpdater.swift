import Foundation
#if canImport(UIKit)
import UserNotifications
#endif

/// Opt-in app-icon badge showing the unread count *within the user's current timeline filter*
/// (tag/feed/starred-only selections), not the full library. Hooked into
/// `ArticleStore.publish(_:)` so it recomputes on every sync pull and every local star/read write —
/// the same single choke point that already drives everything else keyed off the article index.
@MainActor
enum UnreadBadgeUpdater {
    /// The pure count: applies the same `TimelineFiltering` pipeline the on-screen list uses, then
    /// counts unread among the result. Split out from `refresh` so it's testable without touching
    /// `UNUserNotificationCenter`.
    static func count(from summaries: [ArticleSummary], settings: AppSettings) -> Int {
        let byTag = TagFilter.apply(
            to: summaries, disabledTagNames: settings.disabledTagNames, includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let filtered = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        return filtered.filter { !$0.isRead }.count
    }

    /// Recomputes and pushes the system badge, or clears it when the setting is off.
    static func refresh(summaries: [ArticleSummary], settings: AppSettings = AppSettings()) {
        #if canImport(UIKit)
        guard settings.showUnreadBadge else {
            UNUserNotificationCenter.current().setBadgeCount(0)
            return
        }
        UNUserNotificationCenter.current().setBadgeCount(count(from: summaries, settings: settings))
        #endif
    }
}
