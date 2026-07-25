import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSyncCanonicalSnapshot")
struct ArticleSyncCanonicalSnapshotTests {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "ArticleSyncCanonicalSnapshot.\(UUID().uuidString)")!
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext) -> ArticleSyncService {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = true
        return ArticleSyncService(store: store, context: context, settings: settings, defaults: suite())
    }

    @Test func snapshotReturnsCanonicalCreatedAtByUID() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        try context.save()

        let fixed = Date(timeIntervalSince1970: 1_000)
        let store = FakeArticleZoneStore()
        store.seedRemote(SyncedArticleRecord(
            uid: "u1", feedIdentifier: "f1", aggregatorType: "feed_content", articleIdentifier: "a1",
            title: "T", url: "https://x/a1", author: "", summary: "", plainText: "T",
            leadImageRef: "", iconURL: nil, date: .now, createdAt: fixed, blockData: Data(),
            isStarred: false, tagNames: [], imageHashes: []))

        let service = makeService(store, context)
        await service.pull()

        let snap = service.canonicalCreatedAtSnapshot()
        #expect(snap["u1"] == fixed)
    }
}
