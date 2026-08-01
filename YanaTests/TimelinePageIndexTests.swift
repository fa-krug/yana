import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Timeline page index")
struct TimelinePageIndexTests {
    private func article(_ id: String) -> Article {
        Article(title: id, identifier: id, url: "https://x.com/\(id)")
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    /// Builds a real `ArticleSummary` (backed by a real `Article`/`Feed`) so `uid` is the actual
    /// `ArticleUID.make` derivation rather than a hand-rolled string.
    private func summary(_ id: String, feedIdentifier: String = "f", in context: ModelContext) -> ArticleSummary {
        let feed = Feed(name: "Feed", aggregatorType: .feedContent, identifier: feedIdentifier)
        let article = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        article.feed = feed
        context.insert(feed); context.insert(article)
        return ArticleSummary(article)
    }

    @Test func returnsIndexOfMatchingIdentifier() {
        let list = [article("a"), article("b"), article("c")]
        #expect(TimelinePageIndex.index(of: "a", in: list) == 0)
        #expect(TimelinePageIndex.index(of: "c", in: list) == 2)
    }

    @Test func returnsNilWhenAbsentOrNil() {
        let list = [article("a"), article("b")]
        #expect(TimelinePageIndex.index(of: "missing", in: list) == nil)
        #expect(TimelinePageIndex.index(of: nil, in: list) == nil)
        #expect(TimelinePageIndex.index(of: "a", in: [] as [Article]) == nil)
    }

    @Test func anchorFallsBackToNewest() {
        let list = [article("a"), article("b")]
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        // Missing / nil memory resolves to the newest article (last index), not the oldest.
        #expect(TimelineAnchor.index(for: "missing", in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: list) == 1)
    }

}
