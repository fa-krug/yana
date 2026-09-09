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
@MainActor
@Suite("Mac sidebar launch scroll")
struct MacSidebarLaunchScrollTests {
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

    /// The outermost scroll view that actually scrolls — SwiftUI's List host. (The reader scroll
    /// tests document why "the last scroll view in the tree" is the wrong pick.)
    private func listScrollView(_ root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? UIScrollView, scroll.isScrollEnabled { return scroll }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    private struct Harness: View {
        let model: TimelineModel
        let store: ArticleStore
        let settings: AppSettings
        @FocusState private var focusedPane: MacFocusPane?

        var body: some View {
            MacSidebarView(model: model, settings: settings, onCreateFeed: {}, focusedPane: $focusedPane)
                .onAppear {
                    model.applyTimeline()
                }
                .onChange(of: store.summaries) { _, _ in model.applyTimeline() }
        }
    }

    @Test func aSidebarThatAppearedBeforeTheStoreLoadedStillLandsOnTheAnchor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles: [Article] = []
        for i in 0..<120 {
            let article = Article(title: "Article \(i)", identifier: "https://example.com/\(i)",
                                  url: "https://example.com/\(i)", date: .now, author: "Author")
            article.serverID = 100 + i
            article.createdAt = Date(timeIntervalSince1970: Double(1_700_000_000 + i))
            article.feed = feed
            context.insert(article)
            articles.append(article)
        }
        try context.save()

        let settings = freshSettings()
        let anchor = articles[60]
        settings.timelineAnchorIdentifier = anchor.identifier
        settings.timelineAnchorServerID = anchor.serverID

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-sidebar-launch-\(UUID().uuidString).plist")
        let cache = SummaryIndexCache(fileURL: cacheURL)
        await cache.save(articles.map { ArticleSummary($0) })
        let store = ArticleStore(container: container, cache: cache, anchorProvider: {
            (settings.timelineAnchorIdentifier, settings.timelineAnchorServerID)
        })
        let model = TimelineModel(settings: settings)
        model.configure(modelContext: context, store: store)

        let host = UIHostingController(rootView: Harness(model: model, store: store, settings: settings)
            .environment(store)
            .environment(settings)
            .modelContainer(container))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        // The sidebar is on screen with an empty timeline: the real launch order.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.filteredArticles.isEmpty, "the store must not have published before the sidebar appeared")

        store.start()
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()

        #expect(model.selectedSummary?.identifier == anchor.identifier, "the model itself did not park on the anchor")
        let scroll = try #require(listScrollView(host.view), "no list scroll view hosted")
        #expect(scroll.contentSize.height > scroll.bounds.height * 3, "list too short to prove anything: \(scroll.contentSize.height)")
        print("PROBE sidebar-launch: offset \(scroll.contentOffset.y) of \(scroll.contentSize.height)")
        #expect(scroll.contentOffset.y > 0, "the sidebar stayed at the top instead of scrolling to the anchored article")

        window.isHidden = true
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

        let host = UIHostingController(rootView: Harness(model: model, store: store, settings: settings)
            .environment(store)
            .environment(settings)
            .modelContainer(container))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        // An empty library, fully loaded: the sidebar is showing its empty state.
        store.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.hasLoaded)
        #expect(store.summaries.isEmpty)

        // The first sync lands, with the anchor pointing at the newest article.
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var anchorIdentifier = ""
        for i in 0..<120 {
            let article = Article(title: "Article \(i)", identifier: "https://example.com/\(i)",
                                  url: "https://example.com/\(i)", date: .now, author: "Author")
            article.serverID = 100 + i
            article.createdAt = Date(timeIntervalSince1970: Double(1_700_000_000 + i))
            article.feed = feed
            context.insert(article)
            anchorIdentifier = article.identifier
            if i == 119 {
                settings.timelineAnchorIdentifier = article.identifier
                settings.timelineAnchorServerID = article.serverID
            }
        }
        try context.save()
        try await Task.sleep(for: .milliseconds(1800))
        window.layoutIfNeeded()

        #expect(model.selectedSummary?.identifier == anchorIdentifier, "the model itself did not park on the anchor")
        let scroll = try #require(listScrollView(host.view), "no list scroll view hosted")
        #expect(scroll.contentSize.height > scroll.bounds.height * 3, "list too short to prove anything: \(scroll.contentSize.height)")
        print("PROBE sidebar-empty-then-filled: offset \(scroll.contentOffset.y) of \(scroll.contentSize.height)")
        #expect(scroll.contentOffset.y > 0, "the sidebar stayed at the top instead of scrolling to the anchored article")

        window.isHidden = true
    }
}
