import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("StarredRegistry")
struct StarredRegistryTests {
    private func makeSuite() -> UserDefaults {
        let suite = "StarredRegistryTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeFeed(identifier: String = "feed1", aggregatorType: AggregatorType = .feedContent, in context: ModelContext) -> Feed {
        let feed = Feed(name: "Test", aggregatorType: aggregatorType, identifier: identifier)
        context.insert(feed)
        return feed
    }

    // MARK: - Persistence round-trip

    @Test func persistenceRoundTrip() throws {
        let defaults = makeSuite()
        let marks: Set<StarredMark> = [
            StarredMark(feedIdentifier: "f1", aggregatorType: "feedContent", articleIdentifier: "a1"),
            StarredMark(feedIdentifier: "f2", aggregatorType: "youtube", articleIdentifier: "a2")
        ]

        let registry1 = StarredRegistry(defaults: defaults)
        let changed = registry1.update(to: marks)
        #expect(changed == true)
        #expect(registry1.all == marks)

        // A fresh registry on the same suite should read back the same marks.
        let registry2 = StarredRegistry(defaults: defaults)
        #expect(registry2.all == marks)
    }

    @Test func updateReturnsFalseWhenUnchanged() throws {
        let defaults = makeSuite()
        let marks: Set<StarredMark> = [
            StarredMark(feedIdentifier: "f1", aggregatorType: "feedContent", articleIdentifier: "a1")
        ]
        let registry = StarredRegistry(defaults: defaults)
        let firstChange = registry.update(to: marks)
        #expect(firstChange == true)

        // Same set: should return false.
        let secondChange = registry.update(to: marks)
        #expect(secondChange == false)
    }

    // MARK: - identifiers(forFeedIdentifier:aggregatorType:)

    @Test func identifiersFiltersToMatchingFeed() throws {
        let defaults = makeSuite()
        let registry = StarredRegistry(defaults: defaults)
        registry.add(StarredMark(feedIdentifier: "f1", aggregatorType: "feedContent", articleIdentifier: "a1"))
        registry.add(StarredMark(feedIdentifier: "f1", aggregatorType: "feedContent", articleIdentifier: "a2"))
        registry.add(StarredMark(feedIdentifier: "f2", aggregatorType: "youtube", articleIdentifier: "a3"))

        let ids = registry.identifiers(forFeedIdentifier: "f1", aggregatorType: "feedContent")
        #expect(ids == ["a1", "a2"])

        let idsOther = registry.identifiers(forFeedIdentifier: "f2", aggregatorType: "youtube")
        #expect(idsOther == ["a3"])

        let idsNone = registry.identifiers(forFeedIdentifier: "missing", aggregatorType: "feedContent")
        #expect(idsNone.isEmpty)
    }

    @Test func identifiersDoesNotMatchWrongAggregatorType() throws {
        let defaults = makeSuite()
        let registry = StarredRegistry(defaults: defaults)
        registry.add(StarredMark(feedIdentifier: "f1", aggregatorType: "youtube", articleIdentifier: "a1"))

        let ids = registry.identifiers(forFeedIdentifier: "f1", aggregatorType: "feedContent")
        #expect(ids.isEmpty)
    }

    // MARK: - collect(from:)

    @Test func collectMapsStarredArticlesToMarks() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        try context.save()
        let starredTag = try #require(try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn })).first)

        let feed = makeFeed(in: context)
        let article = Article(title: "T", identifier: "a1", url: "https://x.com")
        article.feed = feed
        context.insert(article)
        article.setStarred(true, using: starredTag)

        let marks = StarredRegistry.collect(from: context)
        #expect(marks.count == 1)
        let mark = try #require(marks.first)
        #expect(mark.feedIdentifier == "feed1")
        #expect(mark.aggregatorType == AggregatorType.feedContent.rawValue)
        #expect(mark.articleIdentifier == "a1")
    }

    @Test func collectSkipsNonStarredArticles() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        try context.save()

        let feed = makeFeed(in: context)
        let article = Article(title: "T", identifier: "a1", url: "https://x.com")
        article.feed = feed
        context.insert(article)
        // Not starred.

        let marks = StarredRegistry.collect(from: context)
        #expect(marks.isEmpty)
    }

    @Test func collectSkipsArticlesWithNilFeed() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        try context.save()
        let starredTag = try #require(try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn })).first)

        // Article with no feed.
        let article = Article(title: "T", identifier: "orphan", url: "https://x.com")
        context.insert(article)
        article.setStarred(true, using: starredTag)

        let marks = StarredRegistry.collect(from: context)
        #expect(marks.isEmpty)
    }

    // MARK: - applyToLocalArticles(in:)

    @Test func applyStarsArticleWhoseMarkIsInRegistry() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        try context.save()

        let feed = makeFeed(in: context)
        let article = Article(title: "T", identifier: "a1", url: "https://x.com")
        article.feed = feed
        context.insert(article)
        #expect(article.isStarred == false)

        let defaults = makeSuite()
        let registry = StarredRegistry(defaults: defaults)
        registry.add(StarredMark(feedIdentifier: "feed1", aggregatorType: AggregatorType.feedContent.rawValue, articleIdentifier: "a1"))

        registry.applyToLocalArticles(in: context)
        #expect(article.isStarred == true)
    }

    @Test func applyUnstarsArticleAbsentFromRegistry() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        try context.save()
        let starredTag = try #require(try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn })).first)

        let feed = makeFeed(in: context)
        let article = Article(title: "T", identifier: "a1", url: "https://x.com")
        article.feed = feed
        context.insert(article)
        article.setStarred(true, using: starredTag)
        #expect(article.isStarred == true)

        // Registry is empty — the star should be removed.
        let defaults = makeSuite()
        let registry = StarredRegistry(defaults: defaults)

        registry.applyToLocalArticles(in: context)
        #expect(article.isStarred == false)
    }
}
