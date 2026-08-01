import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("TimelineAnchorWriter")
struct TimelineAnchorWriterTests {
    private func freshSettings() -> AppSettings {
        let suite = "TimelineAnchorWriterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func summary(_ id: String) throws -> ArticleSummary {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        let feed = Feed(name: "Feed", aggregatorType: .feedContent, identifier: "f")
        let article = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        article.feed = feed
        context.insert(feed); context.insert(article)
        return ArticleSummary(article)
    }

    @Test func recordPersistsBothIdentifierAndUID() throws {
        let settings = freshSettings()
        let writer = TimelineAnchorWriter(settings: settings)
        let a = try summary("a")

        writer.record(a)

        #expect(settings.timelineAnchorIdentifier == "a")
        #expect(settings.timelineAnchorSyncUID == a.uid)
    }

    @Test func recordOverwritesThePreviousAnchor() throws {
        let settings = freshSettings()
        let writer = TimelineAnchorWriter(settings: settings)

        writer.record(try summary("a"))
        writer.record(try summary("b"))
        let c = try summary("c")
        writer.record(c)

        #expect(settings.timelineAnchorIdentifier == "c")
        #expect(settings.timelineAnchorSyncUID == c.uid)
    }
}
