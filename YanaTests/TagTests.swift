import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Tag")
struct TagTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func seedsStarredOnceAndIsIdempotent() throws {
        let context = try makeContext()
        Yana.Tag.ensureBuiltIns(in: context)
        Yana.Tag.ensureBuiltIns(in: context)
        try context.save()

        let starred = try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn }))
        #expect(starred.count == 1)
        #expect(starred.first?.name == Yana.Tag.starredName)
    }

    @Test func feedTagsAreSnapshotIntoArticleTags() throws {
        let context = try makeContext()
        let tag = Yana.Tag(name: "Tech")
        let feed = Feed(name: "Heise", aggregatorType: .heise, identifier: "https://heise.de")
        feed.tags = [tag]
        let article = Article(title: "P", identifier: "p1", url: "https://heise.de/1")
        article.feed = feed
        article.tags = feed.tags
        context.insert(tag); context.insert(feed); context.insert(article)
        try context.save()

        let reloaded = try context.fetch(FetchDescriptor<Article>()).first
        #expect(reloaded?.tags.map(\.name) == ["Tech"])
    }
}
