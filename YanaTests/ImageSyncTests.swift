import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
struct ImageSyncTests {
    private func container() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: config
        )
    }
    private func context() throws -> ModelContext { ModelContext(try container()) }
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgsync-\(UUID().uuidString)")
        return ImageStore(directory: dir)
    }

    @Test func ensureStoredInsertsRowsForDiskBlobs() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let store = tempStore()
        let hash = await store.storeData(Data([9,9,9]), ext: "png")
        await ImageSync.ensureStored(hashes: [hash], container: container, imageStore: store)
        let rows = try ctx.fetch(FetchDescriptor<StoredImage>())
        #expect(rows.count == 1)
        #expect(rows.first?.contentHash == hash)
        #expect(rows.first?.ext == "png")
    }

    @Test func ensureStoredIsIdempotent() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let store = tempStore()
        let hash = await store.storeData(Data([1]), ext: "jpg")
        await ImageSync.ensureStored(hashes: [hash], container: container, imageStore: store)
        await ImageSync.ensureStored(hashes: [hash], container: container, imageStore: store)
        #expect(try ctx.fetch(FetchDescriptor<StoredImage>()).count == 1)
    }

    @Test func materializeWritesMissingFileFromStoredImage() async throws {
        let ctx = try context()
        let store = tempStore()
        let hash = "c7b99f1c681eaad2096f54c0380b8f950fa5cbe47cb3695ed590167c0dfff315" // SHA256([7,7])
        ctx.insert(StoredImage(contentHash: hash, data: Data([7,7]), ext: "jpg"))
        try ctx.save()
        let existedBefore = await store.fileExists(forHash: hash)
        #expect(existedBefore == false)
        let ok = await ImageSync.materialize(hash: hash, context: ctx, imageStore: store)
        #expect(ok == true)
        #expect(await store.fileExists(forHash: hash) == true)
    }
}
