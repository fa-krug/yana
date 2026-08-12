import Foundation
import SwiftData
import Testing
@testable import Yana

/// `DuplicateArticleCleaner` sweeps up the duplicate `Article` rows a device could accumulate
/// from two racing `SyncWriter.upsertSummaries` calls before `SyncCoordinator` existed to
/// serialize every sync (see both types' doc comments).
@MainActor
@Suite("DuplicateArticleCleaner")
struct DuplicateArticleCleanupTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    @Test func keepsTheRowWithContentAndDeletesTheDuplicateWithout() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date.now

        let withContent = Article(title: "Hello", identifier: "a", url: "a", date: now)
        withContent.serverID = 100
        withContent.hasContent = true
        withContent.createdAt = now.addingTimeInterval(10)
        context.insert(withContent)

        let withoutContent = Article(title: "Hello", identifier: "a", url: "a", date: now)
        withoutContent.serverID = 100
        withoutContent.hasContent = false
        withoutContent.createdAt = now
        context.insert(withoutContent)

        try context.save()

        let cleaner = DuplicateArticleCleaner(modelContainer: container)
        let deleted = try await cleaner.deduplicate()
        #expect(deleted == 1)

        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.hasContent == true)
    }

    @Test func picksTheEarliestCreatedAtWhenNeitherDuplicateHasContentYet() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date.now

        let older = Article(title: "Hello", identifier: "a", url: "a", date: now)
        older.serverID = 100
        older.createdAt = now
        context.insert(older)

        let newer = Article(title: "Hello", identifier: "a", url: "a", date: now)
        newer.serverID = 100
        newer.createdAt = now.addingTimeInterval(60)
        context.insert(newer)

        try context.save()

        let cleaner = DuplicateArticleCleaner(modelContainer: container)
        _ = try await cleaner.deduplicate()

        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.createdAt == now)
    }

    @Test func orsStarredAndReadFromTheLosingDuplicateIntoTheSurvivor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date.now

        let survivor = Article(title: "Hello", identifier: "a", url: "a", date: now)
        survivor.serverID = 100
        survivor.hasContent = true
        context.insert(survivor)

        let loser = Article(title: "Hello", identifier: "a", url: "a", date: now)
        loser.serverID = 100
        loser.starred = true
        loser.setRead(true)
        context.insert(loser)

        try context.save()

        let cleaner = DuplicateArticleCleaner(modelContainer: container)
        _ = try await cleaner.deduplicate()

        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.starred == true)
        #expect(remaining.first?.read == true)
    }

    @Test func isANoOpWhenNoArticleSharesAServerID() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date.now

        let first = Article(title: "A", identifier: "a", url: "a", date: now)
        first.serverID = 100
        context.insert(first)

        let second = Article(title: "B", identifier: "b", url: "b", date: now)
        second.serverID = 101
        context.insert(second)

        try context.save()

        let cleaner = DuplicateArticleCleaner(modelContainer: container)
        let deleted = try await cleaner.deduplicate()
        #expect(deleted == 0)

        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 2)
    }
}
