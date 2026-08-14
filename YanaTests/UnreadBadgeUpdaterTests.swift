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
        context.insert(feed)
        let article = Article(title: identifier, identifier: identifier, url: "https://x.com/\(identifier)")
        article.feed = feed
        article.starred = isStarred
        article.read = isRead
        context.insert(article)
        try context.save()
        return ArticleSummary(article)
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
}
