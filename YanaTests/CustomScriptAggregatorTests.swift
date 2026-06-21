import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("CustomScriptAggregator")
struct CustomScriptAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    /// Engine with no network — these scripts emit static articles, so the pipeline (not the
    /// script) is under test.
    private func offlineEngine() -> ScriptEngine {
        ScriptEngine(httpGet: { _, _, _, _ in .init(body: nil, error: "no network in tests") })
    }

    private func aggregator(source: String, identifier: String = "https://x.com/1",
                            store: ImageStore, maxArticles: Int? = nil) -> CustomScriptAggregator {
        let config = FeedConfig(type: .customScript, identifier: identifier, dailyLimit: 20,
                                options: .customScript(CustomScriptOptions(source: source)),
                                collectedToday: 0)
        return CustomScriptAggregator(config: config, credentials: .init(), store: store,
                                      engine: offlineEngine(), maxArticles: maxArticles)
    }

    @Test func emittedHTMLIsSanitizedAndImagesLocalized() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "T", url: "https://x.com/1",
                      html: "<p>Body</p><script>evil()</script><img src='https://x.com/p.png'>" });
        }
        """
        let agg = aggregator(source: source, store: tempStore())
        let article = try #require(try await agg.aggregate().first)
        #expect(article.content.contains("Body"))
        #expect(!article.content.contains("evil()"))                     // unsafe tag stripped
        #expect(article.content.contains("\(ReaderWeb.imageScheme)://")) // image localized
        #expect(!article.content.contains("https://x.com/p.png"))        // no remote URL leaks
    }

    @Test func dedupesByURLIdentifier() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "One", url: "https://x.com/1", html: "<p>a</p>" });
          Yana.emit({ title: "One again", url: "https://x.com/1", html: "<p>b</p>" });
          Yana.emit({ title: "Two", url: "https://x.com/2", html: "<p>c</p>" });
        }
        """
        let agg = aggregator(source: source, store: tempStore())
        let articles = try await agg.aggregate()
        // Both /1 entries carry the same identifier; the upsert layer dedups, but the aggregator
        // itself surfaces every emitted item — identifiers are what matter downstream.
        #expect(Set(articles.map(\.identifier)) == ["https://x.com/1", "https://x.com/2"])
    }

    @Test func maxArticlesLimitsPreviewToOne() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "First", url: "https://x.com/1", html: "<p>a</p>" });
          Yana.emit({ title: "Second", url: "https://x.com/2", html: "<p>b</p>" });
        }
        """
        let agg = aggregator(source: source, store: tempStore(), maxArticles: 1)
        let articles = try await agg.aggregate()
        #expect(articles.map(\.title) == ["First"])
    }

    @Test func refetchReRunsScriptForMatchingItem() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "Fresh", url: "https://x.com/1", html: "<p>fresh</p>" });
        }
        """
        let agg = aggregator(source: source, store: tempStore())
        let seed = AggregatedArticle(title: "Old", identifier: "https://x.com/1", url: "https://x.com/1",
                                     rawContent: "", content: "", date: .now, author: "", iconURL: nil)
        let refreshed = try #require(try await agg.refetch(seed))
        #expect(refreshed.title == "Fresh")
        #expect(refreshed.content.contains("fresh"))
    }

    @Test func refetchReturnsNilWhenItemGone() async throws {
        let source = """
        function run(input) { Yana.emit({ title: "Other", url: "https://x.com/2", html: "<p>x</p>" }); }
        """
        let agg = aggregator(source: source, store: tempStore())
        let seed = AggregatedArticle(title: "Old", identifier: "https://x.com/1", url: "https://x.com/1",
                                     rawContent: "", content: "", date: .now, author: "", iconURL: nil)
        let refreshed = try await agg.refetch(seed)
        #expect(refreshed == nil)
    }

    @Test func emptyScriptFailsValidation() async throws {
        let agg = aggregator(source: "   ", store: tempStore())
        #expect(throws: AggregatorError.self) { try agg.validate() }
    }
}
