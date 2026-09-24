#if os(macOS)
import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Yana

/// Pins "on macOS the list is not jumping to the current article": the reader opened on the
/// anchored article while the sidebar sat at the top of the list.
///
/// The launch order that produced it: the sidebar appears *before* `ArticleStore` has published
/// anything (`ArticleStore.start()` runs from the scene's `.task`, and its first publish waits on
/// the disk cache), so the sidebar saw an empty timeline, decided there was nothing to restore an
/// anchor to, and revealed its rows. When the index then landed and the anchor scroll was
/// requested, the launch scroll path treated "already revealed" as "already landed" and never
/// issued a single `scrollTo`.
///
/// The harness mirrors `MacRootView`'s wiring (configure + `applyTimeline` on appear, re-apply on
/// every `store.summaries` change) around a real `MacSidebarView`, hosts it in a window, and only
/// starts the store *after* the view is on screen — exactly the real launch order. The cache is
/// pre-warmed with the whole index so the store publishes once, as a warm cold start does.
///
/// **Why this is now a macOS test, and what had to be true before it could be.** It was written as
/// an iOS test only because Mac Catalyst made that the one safe way to run it: a Mac *UI* test
/// drives the shipping app against the developer's real preferences and login Keychain, which is
/// how a test run could unpair the device or move the real reading anchor. A native macOS *unit*
/// test is a different animal — it runs in-process and injects its own state — but "in-process"
/// is not by itself isolation, so each seam this exercises was checked:
///
/// * `AppSettings` — injected over a throwaway `UserDefaults` suite, so every preference this
///   writes (the timeline anchor above all) lands there and never in `.standard`.
/// * `ModelContainer` — in-memory; `SummaryIndexCache` — a file in the temp directory.
/// * `ArticleStore` / `TimelineModel` / `MacSidebarView` — every dependency is injected; none of
///   them reaches for a shared singleton.
/// * **`ArticleWrites` is the one that is not injected, and it is the reason the fixtures below
///   carry no `serverID`.** Parking on an article marks it read, and `TimelineModel` calls
///   `ArticleWrites.markRead` without threading its own settings through, so that call resolves
///   pairing from `AppSettings()` — i.e. the *real* defaults — and `KeychainService`. On a
///   developer's paired Mac that resolves a live client and would fire a real
///   `PATCH /api/v1/articles/<id>` against their own server, marking whatever real article happens
///   to hold that id as read, and on failure would enqueue a fixture id into the real app's
///   pending-write queue. `ArticleWrites.setRead` guards `let serverID = article.serverID`, so
///   leaving `serverID` nil makes that whole path structurally unreachable: the write stays local
///   to the in-memory container. Nothing here needs a `serverID` — `createdAt` is distinct per
///   article so `TimelineOrder`'s tiebreak never engages, and `stableKey` falls back to the
///   identifier, which is what the assertions key on. Since then `AuthenticatedClient` refuses to
///   resolve a client in a unit-test host reading the standard defaults, which is what lets
///   `aSyncedLibraryLandsOnTheAnchorAndFollowsNextArticle` use `serverID`s -- and it has to, since
///   the sidebar bug it pins only exists once `stableKey` and `identifier` differ.
@MainActor
@Suite("Mac sidebar launch scroll")
struct MacSidebarLaunchScrollTestsMacOS {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func freshSettings() -> AppSettings {
        let suite = "MacSidebarLaunchScrollTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    /// Every `NSScrollView` in the tree, in breadth-first order. The iOS twin of this helper has to
    /// test `isScrollEnabled` to skip `SelectableText`'s non-scrolling `UITextView`; AppKit has no
    /// such trap in a `List` (see `ReaderSyncUpdateScrollTestsMacOS` for the reader's version of the
    /// same point), so the count is asserted instead of a predicate being trusted.
    private func scrollViews(_ root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? NSScrollView { found.append(scroll) }
            queue.append(contentsOf: next.subviews)
        }
        return found
    }

    private struct Harness: View {
        let model: TimelineModel
        let store: ArticleStore
        let settings: AppSettings
        @FocusState private var focusedPane: MacFocusPane?

        var body: some View {
            MacSidebarView(model: model, settings: settings, focusedPane: $focusedPane)
                .onAppear {
                    model.applyTimeline()
                }
                .onChange(of: store.summaries) { _, _ in model.applyTimeline() }
        }
    }

    private func host(_ harness: Harness, container: ModelContainer,
                      store: ArticleStore, settings: AppSettings) -> (NSWindow, NSViewController) {
        let controller = NSHostingController(rootView: harness
            .environment(store)
            .environment(settings)
            .modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 844),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderFront(nil)
        window.layoutIfNeeded()
        return (window, controller)
    }

    /// See the suite doc: no `serverID`, deliberately.
    private func seedArticles(_ context: ModelContext, feed: Feed, count: Int) -> [Article] {
        var articles: [Article] = []
        for i in 0..<count {
            let article = Article(title: "Article \(i)", identifier: "https://example.com/\(i)",
                                  url: "https://example.com/\(i)", date: .now, author: "Author")
            article.createdAt = Date(timeIntervalSince1970: Double(1_700_000_000 + i))
            article.feed = feed
            context.insert(article)
            articles.append(article)
        }
        return articles
    }

    @Test func aSidebarThatAppearedBeforeTheStoreLoadedStillLandsOnTheAnchor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        let articles = seedArticles(context, feed: feed, count: 120)
        try context.save()

        let settings = freshSettings()
        let anchor = articles[60]
        settings.timelineAnchorIdentifier = anchor.identifier

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-sidebar-launch-\(UUID().uuidString).plist")
        let cache = SummaryIndexCache(fileURL: cacheURL)
        await cache.save(articles.map { ArticleSummary($0) })
        let store = ArticleStore(container: container, cache: cache, anchorProvider: {
            (settings.timelineAnchorIdentifier, settings.timelineAnchorServerID)
        })
        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)

        let (window, controller) = host(Harness(model: model, store: store, settings: settings),
                                        container: container, store: store, settings: settings)
        defer { window.orderOut(nil) }
        // The sidebar is on screen with an empty timeline: the real launch order.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.filteredArticles.isEmpty, "the store must not have published before the sidebar appeared")

        store.start()
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()

        #expect(model.selectedSummary?.identifier == anchor.identifier, "the model itself did not park on the anchor")
        let scrolls = scrollViews(controller.view)
        #expect(scrolls.count == 1, "expected exactly one NSScrollView hosting the list, found \(scrolls.count)")
        let scroll = try #require(scrolls.first, "no list scroll view hosted")
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height * 3,
                "list too short to prove anything: \(document.frame.height)")
        #expect(scroll.contentView.bounds.origin.y > 0,
                "the sidebar stayed at the top instead of scrolling to the anchored article")
    }

    /// The shipping launch order since `YanaApp.init` preloads the store: the index is already
    /// published when the sidebar first appears, so no `store.summaries` change ever arrives to
    /// trigger the anchor scroll -- `onAppear`'s `applyTimeline()` has to do it on its own.
    @Test func aSidebarAppearingOverAPreloadedStoreLandsOnTheAnchor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        let articles = seedArticles(context, feed: feed, count: 120)
        try context.save()

        let settings = freshSettings()
        let anchor = articles[60]
        settings.timelineAnchorIdentifier = anchor.identifier

        let cache = SummaryIndexCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-sidebar-preload-\(UUID().uuidString).bin"))
        await cache.save(articles.map { ArticleSummary($0) })
        let store = ArticleStore(container: container, cache: cache, anchorProvider: {
            (settings.timelineAnchorIdentifier, settings.timelineAnchorServerID)
        })
        store.preloadSynchronously()
        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)

        let (window, controller) = host(Harness(model: model, store: store, settings: settings),
                                        container: container, store: store, settings: settings)
        defer { window.orderOut(nil) }
        store.start()
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()

        #expect(model.selectedSummary?.identifier == anchor.identifier, "the model itself did not park on the anchor")
        let scroll = try #require(scrollViews(controller.view).first, "no list scroll view hosted")
        #expect(scroll.contentView.bounds.origin.y > 0,
                "the sidebar stayed at the top instead of scrolling to the anchored article")
    }

    /// Synced articles carry a `serverID`, so their `stableKey` ("s<id>") differs from their
    /// `identifier`. The first two tests only cover the identifier-fallback case, where the two
    /// coincide, and so could not see a scroll request keyed by one value while the rows were keyed
    /// by the other: on a real, paired library the sidebar then never moved at all.
    ///
    /// Safe to give these fixtures `serverID`s now, unlike when the suite doc above was written:
    /// `AuthenticatedClient.current(settings:)` refuses to resolve a client inside a unit-test host
    /// when reading the standard defaults, so `ArticleWrites.markRead` stays local.
    @Test func aSyncedLibraryLandsOnTheAnchorAndFollowsNextArticle() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        let articles = seedArticles(context, feed: feed, count: 120)
        for (i, article) in articles.enumerated() { article.serverID = 10_000 + i }
        try context.save()

        let settings = freshSettings()
        let anchor = articles[60]
        settings.timelineAnchorIdentifier = anchor.identifier
        settings.timelineAnchorServerID = anchor.serverID

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-sidebar-synced-\(UUID().uuidString).plist")
        let cache = SummaryIndexCache(fileURL: cacheURL)
        await cache.save(articles.map { ArticleSummary($0) })
        let store = ArticleStore(container: container, cache: cache, anchorProvider: {
            (settings.timelineAnchorIdentifier, settings.timelineAnchorServerID)
        })
        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)

        let (window, controller) = host(Harness(model: model, store: store, settings: settings),
                                        container: container, store: store, settings: settings)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        store.start()
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()

        #expect(model.selectedSummary?.serverID == anchor.serverID, "the model itself did not park on the anchor")
        let scroll = try #require(scrollViews(controller.view).first, "no list scroll view hosted")
        let launchOffset = scroll.contentView.bounds.origin.y
        #expect(launchOffset > 0, "the sidebar stayed at the top instead of scrolling to the anchored article")

        // Walk far enough down that the selected row must leave the viewport unless the list follows.
        for _ in 0..<40 { model.moveSelection(by: 1) }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        #expect(model.selectedSummary?.serverID == articles[100].serverID)
        #expect(scroll.contentView.bounds.origin.y > launchOffset,
                "the sidebar did not follow Next Article")
    }

    /// The rows may legitimately be visible before the first scroll request ever arrives: a
    /// library that was empty at launch and is filled by the first sync, or the reveal backstop
    /// firing on a slow cache load. Being revealed must not mean the request is dropped.
    @Test func aSidebarRevealedOnAnEmptyLibraryStillScrollsWhenTheAnchorArrives() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = freshSettings()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-sidebar-empty-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: {
            (settings.timelineAnchorIdentifier, settings.timelineAnchorServerID)
        })
        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)

        let (window, controller) = host(Harness(model: model, store: store, settings: settings),
                                        container: container, store: store, settings: settings)
        defer { window.orderOut(nil) }
        // An empty library, fully loaded: the sidebar is showing its empty state.
        store.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.hasLoaded)
        #expect(store.summaries.isEmpty)

        // The first sync lands, with the anchor pointing at the newest article.
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        let articles = seedArticles(context, feed: feed, count: 120)
        let anchorIdentifier = try #require(articles.last).identifier
        settings.timelineAnchorIdentifier = anchorIdentifier
        try context.save()
        try await Task.sleep(for: .milliseconds(1800))
        window.layoutIfNeeded()

        #expect(model.selectedSummary?.identifier == anchorIdentifier, "the model itself did not park on the anchor")
        let scroll = try #require(scrollViews(controller.view).first, "no list scroll view hosted")
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height * 3,
                "list too short to prove anything: \(document.frame.height)")
        #expect(scroll.contentView.bounds.origin.y > 0,
                "the sidebar stayed at the top instead of scrolling to the anchored article")
    }
}
#endif
