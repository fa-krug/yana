import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("RetentionCleanup")
struct RetentionCleanupTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func article(_ id: String, createdAt: Date) -> Article {
        let a = Article(title: id, identifier: id, url: id)
        a.createdAt = createdAt
        return a
    }

    @Test func deletesOldUnstarredKeepsRecentAndStarred() throws {
        let context = try makeContext()
        let starred = Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true)
        context.insert(starred)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        let recent = article("recent", createdAt: now.addingTimeInterval(-5 * 24 * 3600))
        let old = article("old", createdAt: now.addingTimeInterval(-40 * 24 * 3600))
        let oldStarred = article("oldStarred", createdAt: now.addingTimeInterval(-40 * 24 * 3600))
        context.insert(recent); context.insert(old); context.insert(oldStarred)
        oldStarred.tags = [starred]

        RetentionCleanup.run(context: context, retentionDays: 30, now: now)

        let remaining = try context.fetch(FetchDescriptor<Article>()).map(\.identifier).sorted()
        #expect(remaining == ["oldStarred", "recent"])
    }
}
