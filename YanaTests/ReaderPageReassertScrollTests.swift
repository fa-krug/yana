import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Yana

/// Probes the one call both reported "jumps to the top" symptoms route through:
/// `pageController.setViewControllers([displayed], ...)` re-asserting the page that is *already*
/// displayed. `ReaderArticleViewController` does that in two places — `reconcile` when the
/// displayed article's neighbors changed (a background sync appending articles next to the one the
/// user is parked on) and `rewarmNeighborsAfterReturn` on every `willEnterForeground` (returning to
/// a backgrounded app). Neither changes which article is shown, so neither should move the reading
/// position within it.
@MainActor
struct ReaderPageReassertScrollTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    private func body(_ i: Int) -> [Block] {
        var blocks: [Block] = [.heading(level: 1, runs: [InlineRun(text: "Article \(i)")])]
        for p in 0..<10 {
            blocks.append(.paragraph([InlineRun(
                text: "Paragraph \(p). " + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 6)
            )]))
        }
        return blocks
    }

    /// The reader's actual body scroll view — the outermost *scrollable* one (SwiftUI's
    /// `HostingScrollView`). Deliberately not "the last scroll view found": `SelectableText`'s
    /// `UITextView` is also a `UIScrollView`, sits deeper in the tree, and has `isScrollEnabled
    /// == false` with `contentSize == bounds`. Setting `contentOffset` on it succeeds and reads
    /// back, but scrolls nothing and is discarded on the next text layout — so measuring it
    /// reports a "reading position" the reader never had.
    private func bodyScrollView(_ root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? UIScrollView, scroll.isScrollEnabled { return scroll }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// Builds a reader parked on `index`, scrolled 600pt into the body, and hands back everything
    /// keep poking at it.
    private func makeParkedReader(
        context: ModelContext, articles: inout [Article], feed: Feed, index: Int
    ) async throws -> (reader: ReaderArticleViewController, window: UIWindow, page: UIViewController, scroll: UIScrollView, target: CGFloat) {
        let captured = articles
        let reader = ReaderArticleViewController()
        reader.resolveArticle = { summary in captured.first { $0.serverID == summary.serverID } }
        let nav = UINavigationController(rootViewController: reader)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = nav
        window.isHidden = false
        reader.configure(articles: articles.map { ArticleSummary($0) }, index: index)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        let page = try #require(reader.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let scroll = try #require(bodyScrollView(page.view), "no hosted scroll view")
        #expect(scroll.contentSize.height > 1200, "body too short to scroll: \(scroll.contentSize.height)")
        let target = scroll.contentOffset.y + 600
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(scroll.contentOffset.y == target)
        return (reader, window, page, scroll, target)
    }

    private func seed(context: ModelContext, feed: Feed, count: Int) throws -> [Article] {
        var articles: [Article] = []
        for i in 0..<count {
            let article = Article(title: "Article \(i)", identifier: "https://example.com/\(i)",
                                  url: "https://example.com/\(i)", date: .now, author: "Author")
            article.serverID = 100 + i
            article.createdAt = Date(timeIntervalSince1970: Double(1_700_000_000 + i))
            article.feed = feed
            article.blocks = body(i)
            article.hasContent = true
            context.insert(article)
            articles.append(article)
        }
        try context.save()
        return articles
    }

    /// Returning from the background re-asserts the displayed page to force a neighbor re-query.
    /// The article never changes, so the reading position inside it must not either.
    @Test func returningFromTheBackgroundKeepsTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles = try seed(context: context, feed: feed, count: 8)

        let parked = try await makeParkedReader(context: context, articles: &articles, feed: feed, index: 4)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        parked.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        parked.window.layoutIfNeeded()

        let current = try #require(parked.reader.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let after = bodyScrollView(current.view)?.contentOffset.y ?? -1
        print("PROBE foreground re-assert: offset \(parked.target) -> \(after), samePage=\(current === parked.page)")
        #expect(after == parked.target, "the reader jumped to \(after) after returning from the background")
    }

    /// A background sync appending new articles next to the one the user is parked on (the caught-up
    /// case: parked on the newest article) changes its neighbor set, which makes `reconcile`
    /// re-assert the displayed page. Same article, so the position must survive.
    @Test func aSyncAppendingArticlesNextToTheDisplayedOneKeepsTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles = try seed(context: context, feed: feed, count: 8)

        // Parked on the newest article — what a caught-up reader is looking at.
        let parked = try await makeParkedReader(context: context, articles: &articles, feed: feed, index: 7)

        let fresh = Article(title: "Article 8", identifier: "https://example.com/8",
                            url: "https://example.com/8", date: .now, author: "Author")
        fresh.serverID = 108
        fresh.createdAt = Date(timeIntervalSince1970: Double(1_700_000_008))
        fresh.feed = feed
        fresh.blocks = body(8)
        fresh.hasContent = true
        context.insert(fresh)
        try context.save()
        articles.append(fresh)

        let captured = articles
        parked.reader.resolveArticle = { summary in captured.first { $0.serverID == summary.serverID } }
        parked.reader.update(articles: articles.map { ArticleSummary($0) }, index: 7)
        parked.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        parked.window.layoutIfNeeded()

        let current = try #require(parked.reader.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let after = bodyScrollView(current.view)?.contentOffset.y ?? -1
        print("PROBE neighbor re-assert: offset \(parked.target) -> \(after), samePage=\(current === parked.page)")
        #expect(after == parked.target, "the reader jumped to \(after) after a sync appended a new neighbor")
    }

    /// A background sync updating the displayed article in place: `/articles/sync` reports it as
    /// updated (`SyncWriter.upsertSummaries` clears `hasContent`), then the content backfill lands
    /// the refreshed body (`SyncWriter.applyContent`). Same row, same server id.
    @Test func anInPlaceSyncUpdateKeepsTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles = try seed(context: context, feed: feed, count: 8)

        let parked = try await makeParkedReader(context: context, articles: &articles, feed: feed, index: 4)

        let displayed = articles[4]
        displayed.hasContent = false
        try context.save()
        parked.reader.update(articles: articles.map { ArticleSummary($0) }, index: 4)
        parked.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        displayed.blocks = body(4) + [.paragraph([InlineRun(text: "A newly arrived comment.")])]
        displayed.hasContent = true
        try context.save()
        parked.reader.update(articles: articles.map { ArticleSummary($0) }, index: 4)
        parked.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        parked.window.layoutIfNeeded()

        let current = try #require(parked.reader.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let after = bodyScrollView(current.view)?.contentOffset.y ?? -1
        print("PROBE in-place update: offset \(parked.target) -> \(after), samePage=\(current === parked.page)")
        #expect(after == parked.target, "the reader jumped to \(after) after an in-place sync update")
    }

    /// Quitting and relaunching. The anchor remembers *which* article the reader was on, but the
    /// position inside it was never persisted at all, so every relaunch dropped the user at the
    /// top of a half-read article. Replays that: park + scroll, background the app, then build a
    /// fresh reader the way a cold launch does.
    @Test func relaunchingKeepsTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles = try seed(context: context, feed: feed, count: 8)

        let settings = AppSettings()
        settings.timelineAnchorIdentifier = articles[4].identifier
        settings.timelineAnchorServerID = articles[4].serverID
        settings.timelineAnchorReadingOffset = 0
        defer {
            settings.timelineAnchorIdentifier = nil
            settings.timelineAnchorServerID = nil
            settings.timelineAnchorReadingOffset = 0
        }

        let parked = try await makeParkedReader(context: context, articles: &articles, feed: feed, index: 4)

        // Going to the background is the last moment a terminated app gets to write anything.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        parked.window.isHidden = true

        // Cold launch: a brand-new reader, configured from the persisted anchor.
        let captured = articles
        let relaunched = ReaderArticleViewController()
        relaunched.resolveArticle = { summary in captured.first { $0.serverID == summary.serverID } }
        let nav = UINavigationController(rootViewController: relaunched)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = nav
        window.isHidden = false
        relaunched.configure(articles: articles.map { ArticleSummary($0) }, index: 4)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()

        let current = try #require(relaunched.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let after = bodyScrollView(current.view)?.contentOffset.y ?? -1
        print("PROBE relaunch: offset \(parked.target) -> \(after)")
        #expect(after == parked.target, "the reader relaunched at \(after) instead of where the user left off")
    }

    /// A background trip that costs the page its layout. iOS purges a suspended app's off-screen
    /// view backing, and a body laid out from scratch comes back at its top — which a unit test
    /// cannot make the system actually do, so the purge is simulated by zeroing the scroll view
    /// between the background and foreground notifications. What this pins is the repair: whatever
    /// zeroed the position, returning to the foreground puts it back.
    @Test func aBackgroundTripThatPurgesTheLayoutStillRestoresTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles = try seed(context: context, feed: feed, count: 8)

        let settings = AppSettings()
        settings.timelineAnchorIdentifier = articles[4].identifier
        settings.timelineAnchorServerID = articles[4].serverID
        settings.timelineAnchorReadingOffset = 0
        defer {
            settings.timelineAnchorIdentifier = nil
            settings.timelineAnchorServerID = nil
            settings.timelineAnchorReadingOffset = 0
        }

        let parked = try await makeParkedReader(context: context, articles: &articles, feed: feed, index: 4)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))

        // Stand in for the system purge: the body comes back laid out from scratch, at its top.
        parked.scroll.setContentOffset(CGPoint(x: 0, y: -parked.scroll.adjustedContentInset.top), animated: false)
        parked.window.layoutIfNeeded()

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        parked.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        parked.window.layoutIfNeeded()

        let current = try #require(parked.reader.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let after = bodyScrollView(current.view)?.contentOffset.y ?? -1
        print("PROBE purged background trip: offset \(parked.target) -> \(after)")
        #expect(after == parked.target, "the reader came back at \(after) after a background trip")
    }
}
