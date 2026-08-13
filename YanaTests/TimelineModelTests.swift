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

    private func insertArticle(_ id: String, into context: ModelContext, date: Date, serverID: Int? = nil) {
        let feed = Feed(name: "Acme", aggregator: "feedContent", identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        article.date = date
        article.feed = feed
        article.serverID = serverID
        context.insert(feed); context.insert(article)
    }

    /// Builds a `TimelineModel` already configured and parked on a 3-article timeline (oldest to
    /// newest: a, b, c), plus the `store` and `center` used to drive it further.
    private func makeConfiguredModel(
        settings: AppSettings
    ) throws -> (model: TimelineModel, store: ArticleStore) {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("a", into: context, date: Date(timeIntervalSince1970: 1))
        insertArticle("b", into: context, date: Date(timeIntervalSince1970: 2))
        insertArticle("c", into: context, date: Date(timeIntervalSince1970: 3))
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { (nil, nil) })

        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)
        return (model, store)
    }

    // MARK: - User-driven selection pushes

    @Test func settingSelectionPushesTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()

        model.selection = "b"

        #expect(model.selectedSummary?.identifier == "b")
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func moveSelectionPushesTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()
        model.currentIndex = 0   // away from the boundary so the move below actually changes the index

        model.moveSelection(by: 1)

        #expect(model.currentIndex == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func settingSelectionMarksTheNewArticleRead() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()   // parks on "a" per the helper's 3-article a/b/c fixture

        model.selection = "b"
        let article = model.resolve(model.selectedSummary!)
        #expect(article?.read == true)
    }

    @Test func moveSelectionMarksTheNewArticleRead() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()
        model.currentIndex = 0

        model.moveSelection(by: 1)
        let article = model.resolve(model.selectedSummary!)
        #expect(article?.read == true)
    }

    /// The bug this guards against: before this fix, `TimelineModel.recomputeFilter()` had no
    /// order-preservation at all, so marking "b" read the instant it's selected immediately moved
    /// it to the back of the read block on the very next recompute -- reshuffling the sidebar under
    /// the user's cursor. `model.selection = "b"` itself doesn't trigger a recompute (that normally
    /// happens asynchronously via the `store.summaries` -> `.onChange` -> `applyTimeline` chain
    /// `MacRootView` wires up outside this test's scope), so this test calls `recomputeFilter()`
    /// directly to exercise exactly the code path that chain would eventually run.
    @Test func settingSelectionKeepsThePinnedArticleAheadOfTheReadBlockAfterRecompute() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()   // parks on "a" per the helper's 3-article a/b/c fixture (dates 1,2,3)

        model.selection = "b"   // marks "b" read; canonical (read-first) order alone would become [b, a, c]
        model.recomputeFilter()

        #expect(model.filteredArticles.map(\.identifier) == ["a", "b", "c"],
                "the just-selected 'b', now read, must stay pinned ahead of the still-unread 'c'")
    }

    // MARK: - Sidebar scroll requests (Task 5)

    /// Pins "macOS also doesn't focus the article list on the current selected article": every
    /// programmatic selection-move path must bump `scrollTarget` so `MacSidebarView` can scroll the
    /// row into view, while the click path (the `selection` setter, which the `List` itself already
    /// follows) must not — bumping there would fight the user's own scrolling.
    @Test func moveSelectionBumpsTheScrollRequest() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
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
        let (model, store) = try makeConfiguredModel(settings: settings)
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
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        #expect(model.scrollTarget == nil)

        model.applyTimeline()

        #expect(model.scrollTarget?.id == model.selectedSummary?.identifier)
    }



    // MARK: - Remote reading-position apply (first load only)

    /// The core cross-device behavior: a reading position pulled from another paired device (see
    /// `AppSettings.pendingRemoteReadingPosition`) is applied at the very first `applyTimeline`
    /// call, taking priority over the plain local-anchor fallback, and is consumed exactly once.
    @Test func applyTimelineJumpsToAPendingRemoteReadingPosition() async throws {
        let settings = freshSettings()
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("a", into: context, date: Date(timeIntervalSince1970: 1), serverID: 10)
        insertArticle("b", into: context, date: Date(timeIntervalSince1970: 2), serverID: 20)
        insertArticle("c", into: context, date: Date(timeIntervalSince1970: 3), serverID: 30)
        try context.save()
        settings.pendingRemoteReadingPosition = 20   // "b"

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { (nil, nil) })
        await store.refreshNow()

        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)
        model.applyTimeline()

        #expect(model.selectedSummary?.identifier == "b")
        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(settings.pendingRemoteReadingPosition == nil, "consumed once applied")
    }

    /// A remote position that doesn't resolve against the current timeline (stale, or an article
    /// this device hasn't synced) must fall back to the plain local anchor, not leave the reader
    /// unparked -- and must still consume the pending value so it isn't retried forever.
    @Test func applyTimelineFallsBackToTheLocalAnchorWhenTheRemotePositionDoesNotResolve() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)   // a/b/c, no serverIDs set
        await store.refreshNow()
        settings.timelineAnchorIdentifier = "a"
        settings.pendingRemoteReadingPosition = 999   // no article has this serverID

        model.applyTimeline()

        #expect(model.selectedSummary?.identifier == "a")
        #expect(settings.pendingRemoteReadingPosition == nil)
    }

    // MARK: - Self-heal reanchor across duplicate identifiers

    /// `Article.identifier` is only a per-feed dedup key -- two different feeds can share the same
    /// source URL. A background timeline mutation (sync landing, a refresh) re-resolves the saved
    /// anchor via the private `reanchorToCurrentArticle`, reached through the second-and-later
    /// `applyTimeline()` call; without `timelineAnchorServerID` disambiguating it, that lookup could
    /// snap the sidebar/reader to a completely different feed's article sharing the anchor's
    /// identifier string -- the exact "going back jumps to a completely other place" bug this pins.
    @Test func applyTimelineReanchorDisambiguatesArticlesThatShareAnIdentifierAcrossFeeds() async throws {
        let settings = freshSettings()
        let container = try makeContainer()
        let context = container.mainContext
        let feedX = Feed(name: "FeedX", aggregator: "feedContent", identifier: "fx")
        let feedY = Feed(name: "FeedY", aggregator: "feedContent", identifier: "fy")
        let dupInFeedX = Article(title: "dup", identifier: "dup", url: "https://x.com/dup")
        dupInFeedX.date = Date(timeIntervalSince1970: 1); dupInFeedX.feed = feedX; dupInFeedX.serverID = 1
        let dupInFeedY = Article(title: "dup", identifier: "dup", url: "https://x.com/dup")
        dupInFeedY.date = Date(timeIntervalSince1970: 2); dupInFeedY.feed = feedY; dupInFeedY.serverID = 2
        context.insert(feedX); context.insert(feedY); context.insert(dupInFeedX); context.insert(dupInFeedY)
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { (nil, nil) })
        await store.refreshNow()

        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)
        model.applyTimeline()   // first load: didRestoreAnchor flips true

        // Simulate the anchor having been recorded against FeedY's copy (serverID 2).
        settings.timelineAnchorIdentifier = "dup"
        settings.timelineAnchorServerID = 2

        model.applyTimeline()   // second call: recomputeFilter() + reanchorToCurrentArticle()

        #expect(model.selectedSummary?.serverID == 2, "must reanchor to FeedY's copy, not FeedX's same-identifier row")
    }

    // MARK: - clampIndex scroll bump (review finding 4)

    /// Review finding 4: a filter toggle that shrinks the timeline past the current selection moves
    /// `currentIndex` via `clampIndex()` — the reader detail pane (indexed by `currentIndex`)
    /// follows automatically, but the sidebar `List` does not re-scroll on its own. Without a
    /// guarded `requestScroll` call here, the reader and the sidebar selection visibly disagree
    /// until the user scrolls manually — the exact symptom this task exists to fix for this one flow.
    @Test func clampIndexBumpsTheScrollRequestWhenItActuallyMoves() async throws {
        let settings = freshSettings()
        let container = try makeContainer()
        let context = container.mainContext
        let feedA = Feed(name: "FeedA", aggregator: "feedContent", identifier: "fa")
        let feedB = Feed(name: "FeedB", aggregator: "feedContent", identifier: "fb")
        let a = Article(title: "a", identifier: "a", url: "https://x.com/a")
        a.date = Date(timeIntervalSince1970: 1); a.feed = feedA
        let b = Article(title: "b", identifier: "b", url: "https://x.com/b")
        b.date = Date(timeIntervalSince1970: 2); b.feed = feedB
        context.insert(feedA); context.insert(feedB); context.insert(a); context.insert(b)
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { (nil, nil) })
        await store.refreshNow()

        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)
        model.applyTimeline()   // parks on the newest, "b" (index 1)
        #expect(model.selectedSummary?.identifier == "b")
        let before = model.scrollTarget

        // Disable FeedB: the timeline shrinks to just "a", so currentIndex (1) must clamp to 0.
        settings.disabledFeedNames = ["FeedB"]
        model.recomputeFilter()
        model.clampIndex()

        #expect(model.selectedSummary?.identifier == "a")
        #expect(model.scrollTarget?.id == "a")
        #expect(model.scrollTarget?.token != before?.token)
    }

    /// The companion guard: when the filter change leaves `currentIndex` in range,
    /// `clampIndex()` must not bump the scroll request — same reasoning as the click path
    /// (`settingSelectionDoesNotBumpTheScrollRequest`): an unnecessary scroll would fight the
    /// user's own scrolling for no reason.
    @Test func clampIndexDoesNotBumpTheScrollRequestWhenTheIndexIsAlreadyValid() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()
        let before = model.scrollTarget

        model.clampIndex()   // filteredArticles unchanged; currentIndex already in range

        #expect(model.scrollTarget?.token == before?.token)
    }
}
