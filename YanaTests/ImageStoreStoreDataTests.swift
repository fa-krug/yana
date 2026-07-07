import Testing
import Foundation
@testable import Yana

@MainActor
struct ImageStoreStoreDataTests {
    private func tempStore() -> (ImageStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imagestore-test-\(UUID().uuidString)")
        return (ImageStore(directory: dir), dir)
    }

    @Test func storeDataRoundTrips() async throws {
        let (store, _) = tempStore()
        let bytes = Data([0x01, 0x02, 0x03, 0x04])

        let hash = await store.storeData(bytes, ext: "jpg")

        let url = await store.fileURL(forHash: hash)
        #expect(url.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func storeDataIsContentAddressed() async throws {
        let (store, _) = tempStore()
        let bytes = Data([0xAA, 0xBB])
        let h1 = await store.storeData(bytes, ext: "jpg")
        let h2 = await store.storeData(bytes, ext: "jpg")
        #expect(h1 == h2)
    }
}
