import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Yana

/// Replays what a background sync does to the article the reader is parked on — the `/articles/sync`
/// update resets `hasContent`, then the content backfill writes the refreshed body (new comments) —
/// and asserts the reader stays where the user was reading.
@MainActor
struct ReaderSyncUpdateScrollTests {

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

    /// The reader's body scroll view: the outermost *scrollable* one (SwiftUI's
    /// `HostingScrollView`). Not "the last scroll view in the tree" — `SelectableText`'s
    /// `UITextView` is also a `UIScrollView`, sits deeper, and has `isScrollEnabled == false`
    /// with `contentSize == bounds`. Writing `contentOffset` on it succeeds and reads back but
    /// scrolls nothing and is dropped on the next text layout, so measuring it reports a reading
    /// position the reader never had.
    private func innerScrollView(_ root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? UIScrollView, scroll.isScrollEnabled { return scroll }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    @Test func aSyncUpdateToTheDisplayedArticleKeepsTheReadingPosition() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        var articles: [Article] = []
        for i in 0..<8 {
            let article = Article(title: "Article \(i)", identifier: "https://example.com/\(i)",
                                  url: "https://example.com/\(i)", date: .now, author: "Author")
            article.serverID = 100 + i
            article.createdAt = Date(timeIntervalSince1970: Double(1_700_000_000 + i))
            article.feed = feed
            article.blocks = body(i, comments: 3)
            article.hasContent = true
            context.insert(article)
            articles.append(article)
        }
        try context.save()

        func summaries() -> [ArticleSummary] {
            articles.map { ArticleSummary($0) }
        }

        let reader = ReaderArticleViewController()
        reader.resolveArticle = { summary in
            articles.first { $0.serverID == summary.serverID }
        }
        let nav = UINavigationController(rootViewController: reader)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = nav
        window.isHidden = false
        reader.configure(articles: summaries(), index: 4)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        let page = try #require(reader.children.compactMap { $0 as? UIPageViewController }.first?
            .viewControllers?.first)
        let scroll = try #require(innerScrollView(page.view), "no hosted scroll view")
        #expect(scroll.contentSize.height > 1200, "body too short to scroll: \(scroll.contentSize.height)")
        scroll.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(scroll.contentOffset.y == 900)

        // The sync: `/articles/sync` reports the article as updated (SyncWriter.upsertSummaries
        // resets hasContent), the timeline republishes, then the content backfill lands the new
        // body with two extra comments (SyncWriter.applyContent).
        let displayed = articles[4]
        displayed.hasContent = false
        try context.save()
        reader.update(articles: summaries(), index: 4)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        displayed.blocks = body(4, comments: 5)
        displayed.hasContent = true
        try context.save()
        reader.update(articles: summaries(), index: 4)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        let after = innerScrollView(page.view)?.contentOffset.y ?? -1
        print("PROBE sync-update: offset 900 -> \(after)")
        #expect(after == 900, "the reader jumped to \(after) after a sync updated the article")
    }
}
