import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSync images")
struct ArticleSyncImageTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncImg.\(UUID().uuidString)")! }
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }
    /// A throwaway on-disk ImageStore in a unique temp dir.
    private func makeImageStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgtest-\(UUID().uuidString)")
        return ImageStore(directory: dir)
    }
    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext, _ images: ImageStore)
        -> ArticleSyncService {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = true
        return ArticleSyncService(store: store, context: context, settings: settings, defaults: suite(), imageStore: images)
    }

    @Test("Pushing an article with a local image uploads the blob once")
    func pushUploadsImageOnce() async throws {
        let images = makeImageStore()
        let bytes = Data("PNGDATA".utf8)
        let hash = await images.storeData(bytes, ext: "png")

        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let a = Article(title: "T", identifier: "a1", url: "https://x/1")
        a.feed = feed
        a.blocks = [.image(ref: "yana-img://\(hash)", caption: [])]
        context.insert(a)
        let b = Article(title: "T2", identifier: "a2", url: "https://x/2")   // references same image
        b.feed = feed
        b.blocks = [.image(ref: "yana-img://\(hash)", caption: [])]
        context.insert(b)
        try context.save()

        let store = FakeArticleZoneStore()
        let service = makeService(store, context, images)
        await service.pushAll()

        #expect(store.uploadedImageHashes == [hash])         // uploaded exactly once despite two refs
    }

    @Test("Reconciling a record hydrates a missing image into the local store")
    func pullHydratesImage() async throws {
        let images = makeImageStore()
        let bytes = Data("REMOTEPNG".utf8)
        // Compute the hash the same way ImageStore would, by storing then removing? Simpler: push
        // from a source store to learn the hash, then hydrate into a fresh store.
        let sourceImages = makeImageStore()
        let hash = await sourceImages.storeData(bytes, ext: "png")

        let store = FakeArticleZoneStore()
        try await store.upsert(articles: [], images: [SyncedImageRecord(hash: hash, ext: "png", data: bytes)])

        let context = try makeContext()
        let service = makeService(store, context, images)
        let record = SyncedArticleRecord(
            uid: "f1|feed_content|a1", feedIdentifier: "f1", aggregatorType: "feed_content", articleIdentifier: "a1",
            title: "T", url: "https://x/1", author: "", summary: "", plainText: "", leadImageRef: "yana-img://\(hash)",
            iconURL: nil, date: .now, createdAt: .now, blockData: Data(), isStarred: false, tagNames: [],
            imageHashes: [hash])
        await service.hydrateImages(for: [record])

        #expect(await images.fileExists(forHash: hash))
    }
}
