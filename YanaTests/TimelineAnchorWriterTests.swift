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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        var pushCount = 0
        let writer = TimelineAnchorWriter(settings: settings, pushAnchor: { _ in pushCount += 1 })
        let a = try summary("a")

        writer.record(a)

        #expect(settings.timelineAnchorIdentifier == "a")
        #expect(settings.timelineAnchorSyncUID == a.uid)
        #expect(pushCount == 1)
    }

    @Test func recordPushesOncePerCall() throws {
        let settings = freshSettings()
        var pushCount = 0
        let writer = TimelineAnchorWriter(settings: settings, pushAnchor: { _ in pushCount += 1 })

        writer.record(try summary("a"))
        writer.record(try summary("b"))
        writer.record(try summary("c"))

        #expect(pushCount == 3)
        #expect(settings.timelineAnchorIdentifier == "c")
    }
}
