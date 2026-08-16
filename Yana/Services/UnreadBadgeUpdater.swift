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
        let disabledTags = settings.disabledTagNames
        let includeUntagged = settings.includeUntagged
        let disabledFeeds = settings.disabledFeedNames
        let starredOnly = settings.starredOnly
        var count = 0
        for s in summaries where !s.isRead {
            if starredOnly && !s.isStarred { continue }
            if !s.feedName.isEmpty && disabledFeeds.contains(s.feedName) { continue }
            if s.tagNames.isEmpty {
                if !includeUntagged { continue }
            } else if !s.tagNames.contains(where: { !disabledTags.contains($0) }) {
                continue
            }
            count += 1
        }
        return count
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
