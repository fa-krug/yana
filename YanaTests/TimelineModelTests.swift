import Foundation
import SwiftData
import Testing
@testable import Yana

/// Pins the Mac timeline's selection/anchor behaviour: which paths persist the reading position,
/// and which of them scroll the sidebar to the selected row.
///
/// Each test builds its own `TimelineModel` against a private `AppSettings` suite (never
/// `.standard`), so these run fast and never race other suites.
@MainActor
@Suite("TimelineModel selection and anchor")
struct TimelineModelTests {
    private func freshSettings() -> AppSettings {
        let suite = "TimelineModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
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
        settings: AppSettings
    ) throws -> (model: TimelineModel, store: ArticleStore) {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("a", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("b", into: context, createdAt: Date(timeIntervalSince1970: 2))
        insertArticle("c", into: context, createdAt: Date(timeIntervalSince1970: 3))
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { nil })

        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)
        return (model, store)
    }

    // MARK: - User-driven selection records the anchor

    @Test func settingSelectionRecordsTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()

        model.selection = "b"

        #expect(model.selectedSummary?.identifier == "b")
        #expect(settings.timelineAnchorIdentifier == "b")
        #expect(settings.timelineAnchorSyncUID == model.selectedSummary?.uid)
    }

    /// The sidebar `List(selection:)` binding is re-read (and written back) after any programmatic
    /// move of `currentIndex`, so re-selecting the row already at `currentIndex` must be a no-op
    /// rather than a redundant anchor write.
    @Test func settingSelectionToTheAlreadyCurrentIdIsANoOp() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()
        model.selection = "b"

        settings.timelineAnchorIdentifier = "sentinel"
        model.selection = "b"   // re-selecting the row already selected: a no-op re-write

        #expect(settings.timelineAnchorIdentifier == "sentinel")
    }

    @Test func moveSelectionRecordsTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()
        model.currentIndex = 0   // away from the boundary so the move below actually changes the index

        model.moveSelection(by: 1)

        #expect(model.currentIndex == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func moveSelectionAtBoundaryDoesNotRecord() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()
        // Parked on the newest (last) article by default; moving forward again is a no-op.
        model.currentIndex = model.filteredArticles.count - 1

        settings.timelineAnchorIdentifier = "sentinel"
        model.moveSelection(by: 1)

        #expect(settings.timelineAnchorIdentifier == "sentinel")
    }

    // MARK: - Self-heal: an anchor for an absent article resolves once it arrives

    /// `reanchorToCurrentArticle` (run from `applyTimeline` on every `store.summaries` delivery)
    /// prefers the canonical UID over the per-device identifier, so an anchor pointing at an article
    /// that isn't in the current delivery self-heals once that article lands on a later one, rather
    /// than being stuck until the next launch.
    @Test func anchorForAnAbsentArticleResolvesOnceItArrives() async throws {
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

        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)
        model.applyTimeline()
        #expect(model.selectedSummary?.identifier == "b")   // parked on the newest, as usual

        // The stored anchor points at "c", which isn't in the library yet. `ArticleUID.make` keys
        // only on (feed identifier, aggregator type, article identifier) when the article identifier
        // is non-empty, so this is exactly the UID the real "c" will have once it arrives, without
        // needing to fabricate a persisted article first.
        let pendingUID = ArticleUID.make(
            feedIdentifier: "f-c", aggregatorType: AggregatorType.feedContent.rawValue,
            articleIdentifier: "c", date: .now, title: "c"
        )
        settings.timelineAnchorSyncUID = pendingUID
        model.applyTimeline()   // "c" isn't in filteredArticles yet, so nothing moves
        #expect(model.selectedSummary?.identifier == "b", "must not jump until the article actually arrives")
        let scrollBeforeSelfHeal = model.scrollTarget

        insertArticle("c", into: context, createdAt: Date(timeIntervalSince1970: 3))
        try context.save()
        await store.refreshNow()
        model.applyTimeline()   // an ordinary refresh delivery

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
        let feedA = Feed(name: "FeedA", aggregatorType: .feedContent, identifier: "fa")
        let feedB = Feed(name: "FeedB", aggregatorType: .feedContent, identifier: "fb")
        let a = Article(title: "a", identifier: "a", url: "https://x.com/a")
        a.createdAt = Date(timeIntervalSince1970: 1); a.feed = feedA
        let b = Article(title: "b", identifier: "b", url: "https://x.com/b")
        b.createdAt = Date(timeIntervalSince1970: 2); b.feed = feedB
        context.insert(feedA); context.insert(feedB); context.insert(a); context.insert(b)
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { nil })
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
