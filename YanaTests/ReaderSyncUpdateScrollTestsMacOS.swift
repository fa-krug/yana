#if os(macOS)
import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Yana

/// The macOS twin of `ReaderSyncUpdateScrollTests`. It ships with the AppKit port of
/// `ReaderBlockViewController` rather than later, because the mapping it guards is the riskiest one
/// in that port: iOS watches the body grow with KVO on `UIScrollView.contentSize`, and macOS has no
/// such observable, so the whole reading-position restore hangs off an `NSView.frameDidChange`
/// notification on the document view instead.
///
/// It drives the page controller directly, with no pager — `ReaderArticleViewController` is
/// iOS-only, and the Mac's own host (`MacReaderDetailView`) shows exactly one page at a time.
///
/// **On the "two scroll views" warning the iOS file carries:** there, a reader page contains both
/// SwiftUI's own scroll view and, deeper, `SelectableText`'s `UITextView` — itself a `UIScrollView`
/// with scrolling disabled, whose `contentOffset` accepts a write, reads back, and scrolls nothing.
/// `SelectableTextMacOS` builds a *bare* `NSTextView` with no enclosing scroll view precisely so
/// that trap cannot exist here. The first test asserts that rather than assuming it.
@MainActor
struct ReaderSyncUpdateScrollTestsMacOS {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    /// A body long enough to scroll, shaped like a story with a comment thread under it.
    private func body(_ i: Int, comments: Int) -> [Block] {
        var blocks: [Block] = [.heading(level: 1, runs: [InlineRun(text: "Article \(i)")])]
        for p in 0..<10 {
            blocks.append(.paragraph([InlineRun(
                text: "Paragraph \(p). " + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 6)
            )]))
        }
        for c in 0..<comments {
            blocks.append(.paragraph([InlineRun(text: "Comment \(c): a reader's reply to the article.")]))
        }
        return blocks
    }

    /// Every `NSScrollView` in the page's tree, in breadth-first order.
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

    /// Build one on-screen page and let it settle: the first paint is plain text, the selectable
    /// upgrade lands a runloop later, and the body keeps growing after that.
    private func makePage(article: Article) async -> (NSWindow, ReaderBlockViewController) {
        let page = ReaderBlockViewController(article: article, allowsFullscreen: false,
                                             onRefresh: nil, onRequestShowBars: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = page
        window.orderFront(nil)
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        return (window, page)
    }

    private func makeArticle(_ context: ModelContext, comments: Int) throws -> Article {
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        let article = Article(title: "Article 4", identifier: "https://example.com/4",
                              url: "https://example.com/4", date: .now, author: "Author")
        article.serverID = 104
        article.createdAt = Date(timeIntervalSince1970: 1_700_000_004)
        article.feed = feed
        article.blocks = body(4, comments: comments)
        article.hasContent = true
        context.insert(article)
        try context.save()
        return article
    }

    /// The bare-`NSTextView` guarantee `bodyScrollView` relies on, plus the coordinate assumption
    /// every offset in the reading-position code is written against: SwiftUI's document view is
    /// flipped, so the clip view's `bounds.origin.y` is 0 at the top of the article and grows
    /// downward — exactly what `UIScrollView.contentOffset.y` meant on iOS. If AppKit ever handed
    /// back an unflipped document view, a saved position would silently restore upside down.
    @Test func theBodyHasExactlyOneScrollViewAndItsOriginMeansDistanceFromTheTop() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let article = try makeArticle(context, comments: 3)
        let (window, page) = await makePage(article: article)
        defer { window.orderOut(nil) }

        let scrolls = scrollViews(page.view)
        #expect(scrolls.count == 1,
                "expected exactly one NSScrollView in a reader page, found \(scrolls.count)")
        let scroll = try #require(scrolls.first)
        let document = try #require(scroll.documentView)
        #expect(document.isFlipped, "SwiftUI's document view must be flipped for saved offsets to mean 'down'")
        #expect(document.frame.height > 1200, "body too short to scroll: \(document.frame.height)")
        #expect(page.readingOffset?.y == 0, "a freshly built page must report the top as 0")

        scroll.contentView.scroll(to: CGPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.readingOffset?.y == 900,
                "readingOffset must report the clip view's own origin, got \(String(describing: page.readingOffset))")
    }

    /// Replays what a background sync does to the article the reader is parked on — the
    /// `/articles/sync` update resets `hasContent`, then the content backfill writes the refreshed
    /// body (two extra comments) and the page is told to `reload()` — and asserts the reader stays
    /// where the user was reading. This is the macOS shape of the iOS test of the same name: there
    /// the pager re-asserts the page, here `MacReaderDetailView.reloadCurrent` re-renders it.
    @Test func aSyncUpdateToTheDisplayedArticleKeepsTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let article = try makeArticle(context, comments: 3)
        let (window, page) = await makePage(article: article)
        defer { window.orderOut(nil) }

        let scroll = try #require(scrollViews(page.view).first, "no hosted scroll view")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.readingOffset?.y == 900)

        article.hasContent = false
        try context.save()
        page.reload()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        article.blocks = body(4, comments: 5)
        article.hasContent = true
        try context.save()
        page.reload()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        let after = page.readingOffset?.y ?? -1
        #expect(after == 900, "the reader jumped to \(after) after a sync updated the article")
    }

    /// The held-until-the-body-can-hold-it rule (`applyPendingReadingOffset`), which on macOS is
    /// driven by the document view's `frameDidChange` notification rather than by KVO on a content
    /// size. A restore asked for before the body has grown must stay pending and then land, not be
    /// consumed against the short first-paint body.
    @Test func aRestoreIsHeldUntilTheBodyCanHoldItAndThenLands() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // A much longer body than the other two tests use, and deliberately so: the window is 900pt
        // tall, so with the 3-comment article the whole scrollable range is only ~695pt and a
        // restore to y = 900 is a position the body genuinely cannot hold. Clamping short would be
        // the *correct* outcome there, which makes it useless as a test of "the restore was held
        // until it could land exactly". This body is tall enough that 900 is reachable.
        let article = try makeArticle(context, comments: 60)

        let page = ReaderBlockViewController(article: article, allowsFullscreen: false,
                                             onRefresh: nil, onRequestShowBars: {})
        // Asked for before the page is in a window at all — the body does not exist yet, let alone
        // at a height that can hold y = 900. Ordering matters: once the page is on screen SwiftUI
        // may lay the body out far enough that the restore lands on the spot and is released, which
        // would make the "still pending" assertion below a statement about layout timing rather
        // than about the hold-until-it-fits rule this test exists for.
        page.restoreReadingOffset(CGPoint(x: 0, y: 900))
        #expect(page.hasPendingReadingOffset)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = page
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        #expect(page.readingOffset?.y == 900,
                "the held restore never landed, got \(String(describing: page.readingOffset))")
        #expect(!page.hasPendingReadingOffset, "the target must be released once the body can hold it")
    }
}
#endif
