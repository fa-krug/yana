import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Yana

/// Pins that `ReaderBlockViewController.setFindQuery` actually brings the current match on screen
/// and paints it -- including a match in a body segment the `LazyVStack` had not built yet, which
/// takes the coarse (SwiftUI `scrollTo`) route before the fine TextKit one.
@MainActor
struct ReaderFindScrollTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    /// Two long runs of prose split by a divider, so the second run is a separate, initially
    /// unbuilt segment; "needle" appears once, deep in the second run.
    private func body() -> [Block] {
        var blocks: [Block] = [.heading(level: 1, runs: [InlineRun(text: "Haystack")])]
        for p in 0..<20 {
            blocks.append(.paragraph([InlineRun(
                text: "Paragraph \(p). " + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 5)
            )]))
        }
        blocks.append(.divider)
        for p in 20..<40 {
            let marker = p == 30 ? "Here is the needle in the haystack. " : ""
            blocks.append(.paragraph([InlineRun(
                text: "Paragraph \(p). " + marker + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 5)
            )]))
        }
        return blocks
    }

    /// The body scroll view: the outermost *scrollable* one (see `ReaderPageReassertScrollTests`
    /// for why "the last scroll view in the tree" would be `SelectableText`'s non-scrolling text view).
    private func bodyScrollView(_ root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? UIScrollView, scroll.isScrollEnabled { return scroll }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    private func textView(in root: UIView, containing needle: String) -> UITextView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let textView = next as? UITextView, (textView.text ?? "").contains(needle) { return textView }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    @Test func findingAWordFarDownScrollsItOnScreenAndHighlightsIt() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "News", identifier: "1")
        context.insert(feed)
        let article = Article(title: "Haystack", identifier: "https://example.com/1",
                              url: "https://example.com/1", date: .now, author: "Author")
        article.serverID = 100
        article.feed = feed
        article.blocks = body()
        article.hasContent = true
        context.insert(article)
        try context.save()

        let page = ReaderBlockViewController(article: article, allowsFullscreen: false,
                                             onRefresh: nil, onRequestShowBars: {})
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = page
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        let scroll = try #require(bodyScrollView(page.view), "no hosted scroll view")
        let before = scroll.contentOffset.y
        #expect(page.findStatus == .idle)

        page.setFindQuery("needle")
        #expect(page.findStatus == .match(current: 1, total: 1))
        // The coarse route retries the fine reveal over a few frames, then the fine scroll animates.
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()

        let after = scroll.contentOffset.y
        #expect(after > before + 500, "the reader did not scroll toward the match (\(before) -> \(after))")

        let host = try #require(textView(in: page.view, containing: "needle"), "the match's text view was never built")
        let text = host.attributedText.string as NSString
        let range = text.range(of: "needle")
        #expect(range.location != NSNotFound)
        #expect(host.attributedText.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil,
                "the current match is not highlighted")

        let glyphs = host.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let lineRect = host.convert(host.layoutManager.boundingRect(forGlyphRange: glyphs, in: host.textContainer), to: window)
        #expect(lineRect.minY >= 0 && lineRect.maxY <= window.bounds.height,
                "the match's line \(lineRect) is not within the window")
    }

    @Test func aQueryWithNoMatchesReportsSoAndDoesNotScroll() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let article = Article(title: "Haystack", identifier: "https://example.com/2",
                              url: "https://example.com/2", date: .now, author: "Author")
        article.blocks = body()
        context.insert(article)
        try context.save()

        let page = ReaderBlockViewController(article: article, allowsFullscreen: false,
                                             onRefresh: nil, onRequestShowBars: {})
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = page
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let scroll = try #require(bodyScrollView(page.view))
        let before = scroll.contentOffset.y
        page.setFindQuery("zebra")
        #expect(page.findStatus == .noMatches)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scroll.contentOffset.y == before)

        page.endFind()
        #expect(page.findStatus == .idle)
    }
}
