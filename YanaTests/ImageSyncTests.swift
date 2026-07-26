import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
struct ImageSyncTests {
    private func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: config
        )
        return ModelContext(container)
    }
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgsync-\(UUID().uuidString)")
        return ImageStore(directory: dir)
    }

    @Test func ensureStoredInsertsRowsForDiskBlobs() async throws {
        let ctx = try context()
        let store = tempStore()
        let hash = await store.storeData(Data([9,9,9]), ext: "png")
        await ImageSync.ensureStored(hashes: [hash], context: ctx, imageStore: store)
        let rows = try ctx.fetch(FetchDescriptor<StoredImage>())
        #expect(rows.count == 1)
        #expect(rows.first?.hash == hash)
        #expect(rows.first?.ext == "png")
    }

    @Test func ensureStoredIsIdempotent() async throws {
        let ctx = try context()
        let store = tempStore()
        let hash = await store.storeData(Data([1]), ext: "jpg")
        await ImageSync.ensureStored(hashes: [hash], context: ctx, imageStore: store)
        await ImageSync.ensureStored(hashes: [hash], context: ctx, imageStore: store)
        #expect(try ctx.fetch(FetchDescriptor<StoredImage>()).count == 1)
    }

    @Test func materializeWritesMissingFileFromStoredImage() async throws {
        let ctx = try context()
        let store = tempStore()
        ctx.insert(StoredImage(hash: "deadbeef", data: Data([7,7]), ext: "jpg"))
        try ctx.save()
        let existedBefore = await store.fileExists(forHash: "deadbeef")
        #expect(existedBefore == false)
        let ok = await ImageSync.materialize(hash: "deadbeef", context: ctx, imageStore: store)
        #expect(ok == true)
        #expect(await store.fileExists(forHash: "deadbeef") == true)
    }
}
