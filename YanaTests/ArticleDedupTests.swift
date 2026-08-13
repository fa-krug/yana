import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleDedup")
struct ArticleDedupTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    @Test func keepsOldestRowAndDeletesTheRest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let older = Article(title: "dup", identifier: "dup", url: "https://x.com/dup")
        older.serverID = 1
        older.createdAt = Date(timeIntervalSince1970: 1)
        let newer = Article(title: "dup", identifier: "dup", url: "https://x.com/dup")
        newer.serverID = 1
        newer.createdAt = Date(timeIntervalSince1970: 2)
        context.insert(older); context.insert(newer)
        try context.save()

        let deduplicator = ArticleDeduplicator(modelContainer: container)
        let removed = try await deduplicator.deduplicate()

        #expect(removed == 1)
        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.createdAt == older.createdAt)
    }

    /// The bug this guards against: keeping the oldest row purely by `createdAt` used to discard
    /// starred/read state that only landed on the newer, since-deduped copy -- silently reverting
    /// the user's star/read action with no error surfaced.
    @Test func reconcilesStarredAndReadStateOntoTheKeptRowBeforeDeletingDuplicates() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let older = Article(title: "dup", identifier: "dup", url: "https://x.com/dup")
        older.serverID = 1
        older.createdAt = Date(timeIntervalSince1970: 1)
        let newer = Article(title: "dup", identifier: "dup", url: "https://x.com/dup")
        newer.serverID = 1
        newer.createdAt = Date(timeIntervalSince1970: 2)
        newer.starred = true
        newer.setRead(true)
        context.insert(older); context.insert(newer)
        try context.save()

        let deduplicator = ArticleDeduplicator(modelContainer: container)
        _ = try await deduplicator.deduplicate()

        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.starred == true)
        #expect(remaining.first?.read == true)
    }

    @Test func leavesNonDuplicatedArticlesUntouched() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Article(title: "a", identifier: "a", url: "https://x.com/a")
        a.serverID = 1
        let b = Article(title: "b", identifier: "b", url: "https://x.com/b")
        b.serverID = 2
        context.insert(a); context.insert(b)
        try context.save()

        let deduplicator = ArticleDeduplicator(modelContainer: container)
        let removed = try await deduplicator.deduplicate()

        #expect(removed == 0)
        #expect(try context.fetch(FetchDescriptor<Article>()).count == 2)
    }
}
