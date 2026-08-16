import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("UnreadBadgeUpdater")
struct UnreadBadgeUpdaterTests {
    private func freshSettings() -> AppSettings {
        let suite = "UnreadBadgeUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeSummary(
        identifier: String, feedName: String = "", tagNames: Set<String> = [],
        isStarred: Bool = false, isRead: Bool = false
    ) throws -> ArticleSummary {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(name: feedName, identifier: identifier + "-feed")

        // Set up tags if provided
        var tagNamesByID: [Int: String] = [:]
        if !tagNames.isEmpty {
            let tags = tagNames.enumerated().map { idx, name -> Yana.Tag in
                let tag = Yana.Tag(name: name)
                context.insert(tag)
                tagNamesByID[idx] = name
                return tag
            }
            feed.tagIDs = Array(tags.enumerated().map { $0.offset })
        }

        context.insert(feed)
        let article = Article(title: identifier, identifier: identifier, url: "https://x.com/\(identifier)")
        article.feed = feed
        article.starred = isStarred
        article.read = isRead
        context.insert(article)
        try context.save()
        return ArticleSummary(article, tagNamesByID: tagNamesByID)
    }

    @Test func countsOnlyUnreadWithNoFilter() throws {
        let settings = freshSettings()
        let summaries = [
            try makeSummary(identifier: "a", isRead: false),
            try makeSummary(identifier: "b", isRead: true),
            try makeSummary(identifier: "c", isRead: false),
        ]
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 2)
    }

    @Test func respectsStarredOnlyFilter() throws {
        let settings = freshSettings()
        settings.starredOnly = true
        let summaries = [
            try makeSummary(identifier: "a", isStarred: true, isRead: false),
            try makeSummary(identifier: "b", isStarred: false, isRead: false),
        ]
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 1)
    }

    @Test func respectsDisabledFeedNamesFilter() throws {
        let settings = freshSettings()
        settings.disabledFeedNames = ["Muted"]
        let summaries = [
            try makeSummary(identifier: "a", feedName: "Muted", isRead: false),
            try makeSummary(identifier: "b", feedName: "Kept", isRead: false),
        ]
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 1)
    }

    @Test func countHonorsAllFiltersInOnePass() throws {
        let settings = freshSettings()
        settings.disabledFeedNames = ["Muted Feed"]
        settings.disabledTagNames = ["Excluded"]
        settings.starredOnly = false
        settings.includeUntagged = false
        let unreadTagged = try makeSummary(identifier: "unreadTagged", feedName: "News", tagNames: ["Included"], isRead: false)
        let readTagged = try makeSummary(identifier: "readTagged", feedName: "News", tagNames: ["Included"], isRead: true)
        let unreadInMutedFeed = try makeSummary(identifier: "unreadMuted", feedName: "Muted Feed", tagNames: ["Included"], isRead: false)
        let unreadUntagged = try makeSummary(identifier: "unreadUntagged", feedName: "News", tagNames: [], isRead: false)
        let summaries = [unreadTagged, readTagged, unreadInMutedFeed, unreadUntagged]
        // Should count: unreadTagged (unread + tagged + not in disabled feed)
        // Should NOT count: readTagged (read), unreadInMutedFeed (disabled feed), unreadUntagged (no tags & includeUntagged=false)
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 1)
    }
}
