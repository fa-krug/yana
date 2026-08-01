import Foundation
import SwiftData
import Testing
@testable import Yana

/// `ReaderAnchorController` is the iOS reader's timeline-anchor logic, extracted out of
/// `ReaderScreen` (a SwiftUI view struct with no test harness in this codebase) specifically so the
/// no-ping-pong guarantee — only a user-driven selection change may push — is a real assertion
/// against a spy, not just a comment claiming two private view methods never call each other.
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

    /// Builds a controller with a spy installed on its `writer`, and returns the spy's running
    /// push count alongside it.
    private func makeSpiedController(settings: AppSettings) -> (controller: ReaderAnchorController, pushCount: () -> Int) {
        var count = 0
        let writer = TimelineAnchorWriter(settings: settings, pushAnchor: { _ in count += 1 })
        let controller = ReaderAnchorController(settings: settings, writer: writer)
        return (controller, { count })
    }

    // MARK: - User-driven writes push

    @Test func saveAnchorPushesTheAnchor() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let (controller, pushCount) = makeSpiedController(settings: settings)

        controller.saveAnchor(at: 1, in: articles)

        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(pushCount() == 1)
    }

    @Test func saveAnchorOutOfBoundsDoesNothing() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context)]
        let (controller, pushCount) = makeSpiedController(settings: settings)

        controller.saveAnchor(at: 5, in: articles)

        #expect(settings.timelineAnchorIdentifier == nil)
        #expect(pushCount() == 0)
    }

    @Test func recordOpenedArticlePushesTheAnchor() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let b = summary("b", in: context)
        let (controller, pushCount) = makeSpiedController(settings: settings)

        controller.recordOpenedArticle(b)

        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(settings.timelineAnchorSyncUID == b.uid)
        #expect(pushCount() == 1)
    }

    // MARK: - Remote-anchor apply: the no-ping-pong guard

    @Test func resolveSyncedAnchorIndexMovesSelectionWithoutPushing() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let (controller, pushCount) = makeSpiedController(settings: settings)

        settings.timelineAnchorSyncUID = articles[1].uid
        let index = controller.resolveSyncedAnchorIndex(didRestoreAnchor: true, in: articles)

        #expect(index == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(pushCount() == 0, "applying a remote anchor must never push, or two open devices would ping-pong forever")
    }

    @Test func resolveSyncedAnchorIndexIgnoresBeforeRestoreOrUnmatchedUID() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let (controller, pushCount) = makeSpiedController(settings: settings)

        settings.timelineAnchorSyncUID = articles[1].uid
        // Not yet restored: must not resolve even though the UID matches.
        #expect(controller.resolveSyncedAnchorIndex(didRestoreAnchor: false, in: articles) == nil)

        // Restored, but the UID hasn't synced to this device yet.
        settings.timelineAnchorSyncUID = "not-synced-yet"
        #expect(controller.resolveSyncedAnchorIndex(didRestoreAnchor: true, in: articles) == nil)

        #expect(pushCount() == 0)
    }

    // MARK: - Reanchor: self-heals a pending remote anchor once it arrives

    @Test func reanchorIndexPrefersSyncedUIDOverIdentifier() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let (controller, pushCount) = makeSpiedController(settings: settings)

        settings.timelineAnchorIdentifier = "a"
        settings.timelineAnchorSyncUID = articles[1].uid   // "b" — deliberately disagreeing with identifier

        #expect(controller.reanchorIndex(in: articles) == 1)
        #expect(settings.timelineAnchorIdentifier == "b", "reanchoring keeps the identifier in lockstep with the UID it resolved")
        #expect(pushCount() == 0, "reanchoring is not a user-driven change and must never push")
    }

    @Test func reanchorIndexFallsBackToIdentifierWhenUIDUnresolved() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context), summary("b", in: context)]
        let (controller, _) = makeSpiedController(settings: settings)

        settings.timelineAnchorIdentifier = "a"
        settings.timelineAnchorSyncUID = "not-synced-yet"

        #expect(controller.reanchorIndex(in: articles) == 0)
    }

    @Test func reanchorIndexSelfHealsOncePendingArticleArrives() throws {
        let settings = freshSettings()
        let context = try makeContext()
        var articles = [summary("a", in: context)]
        let (controller, pushCount) = makeSpiedController(settings: settings)

        settings.timelineAnchorIdentifier = "a"
        // A remote anchor for "b" arrived before "b" itself did — pending, so falls back to "a".
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
        #expect(pushCount() == 0, "self-healing a pending anchor is not a user-driven change and must never push")
    }

    @Test func reanchorIndexReturnsNilWhenNeitherResolves() throws {
        let settings = freshSettings()
        let context = try makeContext()
        let articles = [summary("a", in: context)]
        let (controller, _) = makeSpiedController(settings: settings)

        settings.timelineAnchorIdentifier = "missing"
        settings.timelineAnchorSyncUID = "also-missing"

        #expect(controller.reanchorIndex(in: articles) == nil)
    }
}
