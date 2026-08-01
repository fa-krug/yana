import Foundation
import SwiftData
import Testing
@testable import Yana

/// `ReaderAnchorController` is the iOS reader's timeline-anchor logic, extracted out of
/// `ReaderScreen` (a SwiftUI view struct with no test harness in this codebase) so it can be
/// asserted on directly rather than read.
@MainActor
@Suite("ReaderAnchorController")
struct ReaderAnchorControllerTests {
    private func freshSettings() -> AppSettings {
        let suite = "ReaderAnchorControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func summary(_ id: String, feedIdentifier: String = "f", in context: ModelContext) -> ArticleSummary {
        let feed = Feed(name: "Feed", aggregatorType: .feedContent, identifier: feedIdentifier)
        let article = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        article.feed = feed
        context.insert(feed); context.insert(article)
        return ArticleSummary(article)
    }

    private func makeController(settings: AppSettings) -> ReaderAnchorController {
        ReaderAnchorController(settings: settings)
    }

    // MARK: - User-driven writes

    @Test func saveAnchorRecordsTheAnchor() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let controller = makeController(settings: settings)

        controller.saveAnchor(at: 1, in: articles)

        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(settings.timelineAnchorSyncUID == articles[1].uid)
    }

    @Test func saveAnchorOutOfBoundsDoesNothing() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context)]
        let controller = makeController(settings: settings)

        controller.saveAnchor(at: 5, in: articles)

        #expect(settings.timelineAnchorIdentifier == nil)
    }

    @Test func recordOpenedArticleRecordsTheAnchor() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let b = summary("b", in: context)
        let controller = makeController(settings: settings)

        controller.recordOpenedArticle(b)

        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(settings.timelineAnchorSyncUID == b.uid)
    }

    // MARK: - Reanchor

    @Test func reanchorIndexPrefersSyncedUIDOverIdentifier() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let controller = makeController(settings: settings)

        settings.timelineAnchorIdentifier = "a"
        settings.timelineAnchorSyncUID = articles[1].uid   // "b" — deliberately disagreeing with identifier

        #expect(controller.reanchorIndex(in: articles) == 1)
        #expect(settings.timelineAnchorIdentifier == "b", "reanchoring keeps the identifier in lockstep with the UID it resolved")
    }

    @Test func reanchorIndexFallsBackToIdentifierWhenUIDUnresolved() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let controller = makeController(settings: settings)

        settings.timelineAnchorIdentifier = "a"
        settings.timelineAnchorSyncUID = "not-synced-yet"

        #expect(controller.reanchorIndex(in: articles) == 0)
    }

    @Test func reanchorIndexSelfHealsOncePendingArticleArrives() throws {
        let settings = freshSettings()
        let context = try makeContext()
        var articles = [summary("a", in: context)]
        let controller = makeController(settings: settings)

        settings.timelineAnchorIdentifier = "a"
        // The anchored article isn't in this delivery yet — falls back to the identifier.
        let pendingUID = ArticleUID.make(
            feedIdentifier: "f", aggregatorType: AggregatorType.feedContent.rawValue,
            articleIdentifier: "b", date: .now, title: "b"
        )
        settings.timelineAnchorSyncUID = pendingUID
        #expect(controller.reanchorIndex(in: articles) == 0)

        // "b" arrives on a later timeline delivery — same UID (identifier-keyed), now resolvable.
        articles.append(summary("b", in: context))
        #expect(controller.reanchorIndex(in: articles) == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func reanchorIndexReturnsNilWhenNeitherResolves() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context)]
        let controller = makeController(settings: settings)

        settings.timelineAnchorIdentifier = "missing"
        settings.timelineAnchorSyncUID = "also-missing"

        #expect(controller.reanchorIndex(in: articles) == nil)
    }
}
