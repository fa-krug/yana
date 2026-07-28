import Foundation
import SwiftData
import Testing
@testable import Yana

/// Pins the fix for "the current selected article is not updated when I scroll through the
/// articles" on the Mac side: `TimelineModel` previously had no observer for a synced anchor at
/// all, and the write side never pushed outside of the rare scene `.background` event.
///
/// Each test builds its own `TimelineModel` against a private `AppSettings` suite and a private
/// `NotificationCenter` (never `.default`), mirroring `LibraryRevisionTests`, so these run fast and
/// never race real `AppSettings.timelinePositionDidChange` traffic from other suites.
@MainActor
@Suite("TimelineModel synced anchor")
struct TimelineModelTests {
    private func freshSettings() -> AppSettings {
        let suite = "TimelineModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func insertArticle(_ id: String, into context: ModelContext, createdAt: Date) {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        article.createdAt = createdAt
        article.feed = feed
        context.insert(feed); context.insert(article)
    }

    /// Builds a `TimelineModel` already configured and parked on a 3-article timeline (oldest to
    /// newest: a, b, c), plus the `store` and `center` used to drive it further.
    private func makeConfiguredModel(
        settings: AppSettings, center: NotificationCenter
    ) throws -> (model: TimelineModel, store: ArticleStore, center: NotificationCenter) {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("a", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("b", into: context, createdAt: Date(timeIntervalSince1970: 2))
        insertArticle("c", into: context, createdAt: Date(timeIntervalSince1970: 3))
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { nil })

        let model = TimelineModel(settings: settings, notificationCenter: center)
        model.configure(modelContext: context, store: store)
        return (model, store, center)
    }

    // MARK: - User-driven selection pushes

    @Test func settingSelectionPushesTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()

        var pushed: [String] = []
        model.anchorWriter.pushAnchor = { pushed.append($0.timelineAnchorSyncUID ?? "") }

        model.selection = "b"

        #expect(model.selectedSummary?.identifier == "b")
        #expect(pushed.count == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func moveSelectionPushesTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        model.currentIndex = 0   // away from the boundary so the move below actually changes the index

        var pushCount = 0
        model.anchorWriter.pushAnchor = { _ in pushCount += 1 }

        model.moveSelection(by: 1)

        #expect(model.currentIndex == 1)
        #expect(pushCount == 1)
    }

    @Test func moveSelectionAtBoundaryDoesNotPush() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        // Parked on the newest (last) article by default; moving forward again is a no-op.
        model.currentIndex = model.filteredArticles.count - 1

        var pushCount = 0
        model.anchorWriter.pushAnchor = { _ in pushCount += 1 }

        model.moveSelection(by: 1)

        #expect(pushCount == 0)
    }

    // MARK: - Remote-anchor apply: the no-ping-pong guard

    @Test func jumpToSyncedTimelinePositionMovesSelectionWithoutPushing() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()

        var pushCount = 0
        model.anchorWriter.pushAnchor = { _ in pushCount += 1 }

        // Simulate a remote device's anchor arriving for article "a".
        settings.timelineAnchorSyncUID = model.filteredArticles.first { $0.identifier == "a" }?.uid
        model.jumpToSyncedTimelinePosition()

        #expect(model.selectedSummary?.identifier == "a")
        #expect(pushCount == 0, "applying a remote anchor must never push, or two open devices would ping-pong forever")
    }

    @Test func remoteAnchorNotificationMovesSelectionWithoutPushing() async throws {
        let settings = freshSettings()
        let center = NotificationCenter()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: center)
        await store.refreshNow()
        model.applyTimeline()

        var pushCount = 0
        model.anchorWriter.pushAnchor = { _ in pushCount += 1 }

        settings.timelineAnchorSyncUID = model.filteredArticles.first { $0.identifier == "a" }?.uid
        center.post(name: AppSettings.timelinePositionDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(50))   // observer runs on the main queue, async-dispatched

        #expect(model.selectedSummary?.identifier == "a")
        #expect(pushCount == 0)
    }

    @Test func jumpToSyncedTimelinePositionIgnoresAUIDThatHasNotSyncedYet() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        let before = model.currentIndex

        settings.timelineAnchorSyncUID = "some-uid-not-in-this-library"
        model.jumpToSyncedTimelinePosition()

        #expect(model.currentIndex == before)
    }

    // MARK: - Self-heal: a pending remote anchor resolves once the article arrives

    /// Widens the original brief: `jumpToSyncedTimelinePosition` correctly no-ops on an unmatched
    /// UID, but that is the *likely* case in practice (KVS anchor propagation is typically faster
    /// than the CloudKit article import it's waiting on), and nothing previously re-attempted the
    /// match — `timelinePositionDidChange` won't re-post (the UID hasn't changed since it arrived),
    /// so the position would only catch up at the next launch. `reanchorToCurrentArticle` (run from
    /// `applyTimeline` on every `store.summaries` delivery) now prefers the synced UID over the
    /// identifier, so once the awaited article lands on a later delivery, the selection self-heals
    /// without needing another notification.
    @Test func pendingRemoteAnchorResolvesOnceTheArticleArrives() async throws {
        let settings = freshSettings()
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("a", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("b", into: context, createdAt: Date(timeIntervalSince1970: 2))
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { nil })
        await store.refreshNow()   // store only knows about "a" and "b" so far

        let model = TimelineModel(settings: settings, notificationCenter: NotificationCenter())
        model.configure(modelContext: context, store: store)
        model.applyTimeline()
        #expect(model.selectedSummary?.identifier == "b")   // parked on the newest, as usual

        // A remote device's anchor arrives for "c" — an article that hasn't synced to this device
        // yet. `ArticleUID.make` keys only on (feed identifier, aggregator type, article identifier)
        // when the article identifier is non-empty, so this is exactly the UID the real "c" will
        // have once it arrives, without needing to fabricate a persisted article first.
        let pendingUID = ArticleUID.make(
            feedIdentifier: "f-c", aggregatorType: AggregatorType.feedContent.rawValue,
            articleIdentifier: "c", date: .now, title: "c"
        )
        settings.timelineAnchorSyncUID = pendingUID
        model.jumpToSyncedTimelinePosition()   // ignored: "c" isn't in filteredArticles yet
        #expect(model.selectedSummary?.identifier == "b", "must not jump until the article actually arrives")
        let scrollBeforeSelfHeal = model.scrollTarget

        // Nothing re-posts `timelinePositionDidChange` (the UID hasn't changed) — the self-heal has
        // to come from an ordinary timeline delivery once "c" lands.
        insertArticle("c", into: context, createdAt: Date(timeIntervalSince1970: 3))
        try context.save()
        await store.refreshNow()
        model.applyTimeline()   // an ordinary refresh delivery, not a remote-anchor notification

        #expect(model.selectedSummary?.identifier == "c")
        #expect(settings.timelineAnchorIdentifier == "c")
        // The self-heal in `reanchorToCurrentArticle` moves the selection programmatically, so it
        // must scroll the sidebar too, same as the other programmatic paths.
        #expect(model.scrollTarget?.id == "c")
        #expect(model.scrollTarget?.token != scrollBeforeSelfHeal?.token)
    }

    // MARK: - Sidebar scroll requests (Task 5)

    /// Pins "macOS also doesn't focus the article list on the current selected article": every
    /// programmatic selection-move path must bump `scrollTarget` so `MacSidebarView` can scroll the
    /// row into view, while the click path (the `selection` setter, which the `List` itself already
    /// follows) must not — bumping there would fight the user's own scrolling.
    @Test func moveSelectionBumpsTheScrollRequest() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        model.currentIndex = 0
        let before = model.scrollTarget

        model.moveSelection(by: 1)

        #expect(model.selectedSummary?.identifier == "b")
        #expect(model.scrollTarget?.id == "b")
        #expect(model.scrollTarget?.token != before?.token)
    }

    @Test func settingSelectionDoesNotBumpTheScrollRequest() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        let before = model.scrollTarget

        model.selection = "b"   // the click path: the List already follows this on its own

        #expect(model.selectedSummary?.identifier == "b")
        #expect(model.scrollTarget?.token == before?.token,
                "the click path must not bump the scroll request, or it would fight the user's own scrolling")
    }

    /// The launch case the user reported: the first `applyTimeline` call restores the saved anchor
    /// before the sidebar has any rows laid out, so this is the earliest point a scroll request can
    /// be made at all.
    @Test func applyTimelineBumpsTheScrollRequestOnTheAnchorRestore() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        #expect(model.scrollTarget == nil)

        model.applyTimeline()

        #expect(model.scrollTarget?.id == model.selectedSummary?.identifier)
    }

    @Test func jumpToSyncedTimelinePositionBumpsTheScrollRequest() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        let before = model.scrollTarget

        settings.timelineAnchorSyncUID = model.filteredArticles.first { $0.identifier == "a" }?.uid
        model.jumpToSyncedTimelinePosition()

        #expect(model.selectedSummary?.identifier == "a")
        #expect(model.scrollTarget?.id == "a")
        #expect(model.scrollTarget?.token != before?.token)
    }

    /// The exact sequence the brief calls out: the launch anchor restore is immediately followed by
    /// a remote anchor arriving for that *same* already-selected article. The id doesn't change, but
    /// the token still must, or `MacSidebarView`'s `.onChange(of: model.scrollTarget)` would see an
    /// equal value and never re-issue the scroll.
    @Test func repeatedRequestForTheSameArticleStillBumpsTheToken() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()   // restores the anchor and requests a scroll to the parked article

        let restoredID = model.selectedSummary?.identifier
        let restoredToken = model.scrollTarget?.token

        // A remote anchor for that same already-selected article arrives right after launch.
        settings.timelineAnchorSyncUID = model.selectedSummary?.uid
        model.jumpToSyncedTimelinePosition()

        #expect(model.scrollTarget?.id == restoredID)
        #expect(model.scrollTarget?.token != restoredToken,
                "a repeated request for the same id must not be swallowed by a stale token")
    }
}
