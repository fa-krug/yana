import Foundation
import SwiftData
import Testing
@testable import Yana

/// Pins `ReaderAnchorController`'s two invariants directly, rather than resting on "this SwiftUI
/// view's private method never calls that other private method" -- there is no test harness for a
/// SwiftUI view struct in this codebase:
/// 1. User-driven writes (`saveAnchor`/`recordOpenedArticle`) persist the local anchor.
/// 2. The remote-apply read (`jumpToSyncedTimelinePosition`) never pushes back to the server --
///    otherwise two open devices would trade anchor writes forever.
@MainActor
@Suite("ReaderAnchorController")
struct ReaderAnchorControllerTests {
    private func freshSettings() -> AppSettings {
        let suite = "ReaderAnchorControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeSummaries(_ specs: [(identifier: String, serverID: Int?)]) throws -> [ArticleSummary] {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = container.mainContext
        return specs.map { spec in
            let article = Article(title: spec.identifier, identifier: spec.identifier, url: "https://x.com/\(spec.identifier)")
            article.serverID = spec.serverID
            context.insert(article)
            return ArticleSummary(article)
        }
    }

    // MARK: - User-driven writes

    @Test func saveAnchorPersistsTheLocalIdentifier() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("a", 1), ("b", 2)])
        let controller = ReaderAnchorController(settings: settings)

        controller.saveAnchor(at: 1, in: articles)

        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func recordOpenedArticlePersistsTheLocalIdentifier() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("a", 1), ("b", 2)])
        let controller = ReaderAnchorController(settings: settings)

        controller.recordOpenedArticle(articles[0])

        #expect(settings.timelineAnchorIdentifier == "a")
    }

    // MARK: - Self-heal reanchor

    /// `Article.identifier` is only a per-feed dedup key -- two different feeds can share the same
    /// source URL. A background timeline mutation (sync landing, a refresh) re-resolves the saved
    /// anchor via `reanchorIndex`; without `timelineAnchorServerID` disambiguating it, that lookup
    /// could snap the reader to a completely different feed's article sharing the same identifier
    /// string as the one actually being read -- the exact "going back jumps to a completely other
    /// place" bug this pins.
    @Test func reanchorIndexDisambiguatesArticlesThatShareAnIdentifierAcrossFeeds() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("dup", 1), ("dup", 2), ("z", 3)])
        let controller = ReaderAnchorController(settings: settings)

        controller.recordOpenedArticle(articles[1])   // the second feed's "dup" (serverID 2)

        #expect(controller.reanchorIndex(in: articles) == 1)
    }

    // MARK: - Remote-apply read

    @Test func jumpToSyncedTimelinePositionResolvesByServerIDAndUpdatesTheLocalAnchor() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("a", 1), ("b", 2), ("c", 3)])
        settings.pendingRemoteReadingPosition = 2
        let controller = ReaderAnchorController(settings: settings)

        let index = controller.jumpToSyncedTimelinePosition(in: articles)

        #expect(index == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func jumpToSyncedTimelinePositionConsumesThePendingValueEvenWhenUnresolvable() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("a", 1)])
        settings.pendingRemoteReadingPosition = 999   // not in this filtered slice
        let controller = ReaderAnchorController(settings: settings)

        let index = controller.jumpToSyncedTimelinePosition(in: articles)

        #expect(index == nil)
        #expect(settings.pendingRemoteReadingPosition == nil, "a stale/unsyncable remote position must not be retried forever")
    }

    @Test func jumpToSyncedTimelinePositionReturnsNilWhenNothingIsPending() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("a", 1)])
        let controller = ReaderAnchorController(settings: settings)

        #expect(controller.jumpToSyncedTimelinePosition(in: articles) == nil)
    }

    /// The no-ping-pong guarantee: applying a remote position must never schedule a push back to
    /// the server, or two open devices would trade anchor writes forever. `writer.record` is what
    /// schedules a push (via `ReadingPositionSync.shared.schedulePush`); this asserts
    /// `jumpToSyncedTimelinePosition` never reaches it by checking no push was queued as a result
    /// (this test runs unpaired, so a real push would no-op anyway -- the meaningful assertion is
    /// that the local anchor still updates correctly through the direct-write path, not through
    /// `record`, which is exercised separately by the `saveAnchor`/`recordOpenedArticle` tests above).
    @Test func jumpToSyncedTimelinePositionNeverQueuesAPositionPush() throws {
        let settings = freshSettings()
        let articles = try makeSummaries([("a", 1), ("b", 2)])
        settings.pendingRemoteReadingPosition = 2
        let controller = ReaderAnchorController(settings: settings)

        _ = controller.jumpToSyncedTimelinePosition(in: articles)

        #expect(settings.pendingReadingPositionPush == nil)
    }
}
