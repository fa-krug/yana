import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationRetentionGate")
struct AggregationRetentionGateTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, StoredImage.self,
                                           configurations: config)
        let seed = ModelContext(container)
        seed.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        try seed.save()
        return container
    }

    private struct IdentityAI: AIProcessing {
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] { input }
    }

    private func makeInputs(skipRetention: Bool, retentionDays: Int = 1) -> AggregationRunInputs {
        AggregationRunInputs(
            makeAggregator: { _, _ in nil },
            processor: IdentityAI(),
            logoResolver: { _, _ in nil },
            credentials: .resolved(),
            now: .now,
            starredIdentifiers: { _, _ in [] },
            canonicalCreatedAt: [:],
            isSourceEnabled: { _ in true },
            retentionDays: retentionDays,
            skipRetention: skipRetention,
            progress: { _ in })
    }

    /// When `skipRetention == true`, aged-out articles must NOT be deleted.
    @Test func skipRetentionTruePreservesAgedOutArticle() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed)
        let old = Article(title: "old", identifier: "o1", url: "u", date: .distantPast,
                          author: "", iconURL: nil)
        old.feed = feed
        old.createdAt = .distantPast   // way beyond any retention window
        main.insert(old)
        try main.save()

        let writer = AggregationWriter(modelContainer: container)
        let result = await writer.runUpdateAll(makeInputs(skipRetention: true, retentionDays: 1))

        // Retention skipped: aged-out article must still be present.
        let remaining = try main.fetch(FetchDescriptor<Article>())
        #expect(remaining.count == 1, "Article should be kept when skipRetention is true")
        #expect(result.deletedUIDs.isEmpty, "No UIDs should be reported as deleted when skipRetention is true")
    }

    /// When `skipRetention == false`, aged-out articles MUST be deleted.
    @Test func skipRetentionFalseDeletesAgedOutArticle() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed)
        let old = Article(title: "old", identifier: "o1", url: "u", date: .distantPast,
                          author: "", iconURL: nil)
        old.feed = feed
        old.createdAt = .distantPast   // way beyond any retention window
        main.insert(old)
        try main.save()

        let writer = AggregationWriter(modelContainer: container)
        let result = await writer.runUpdateAll(makeInputs(skipRetention: false, retentionDays: 1))

        // Retention ran: aged-out article must be gone.
        let remaining = try main.fetch(FetchDescriptor<Article>())
        #expect(remaining.isEmpty, "Aged-out article should be deleted when skipRetention is false")
        #expect(!result.deletedUIDs.isEmpty, "Deleted UIDs should be reported when retention ran")
    }
}
