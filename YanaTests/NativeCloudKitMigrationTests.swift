import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
struct NativeCloudKitMigrationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func settings(_ suite: String) -> (AppSettings, UserDefaults) {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: d), d)
    }
    private func tempStore() -> ImageStore {
        ImageStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString)"))
    }

    @Test func seedsImagesAndMapsInterval() async throws {
        let c = try container()
        let (s, d) = settings("mig-a")
        d.set(3600.0, forKey: "settings.backgroundInterval")
        let store = tempStore()
        let hash = await store.storeData(Data([5, 5]), ext: "jpg")

        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: store)

        #expect(try c.mainContext.fetch(FetchDescriptor<StoredImage>()).contains { $0.contentHash == hash })
        #expect(s.updateInterval == .min60)          // 3600s → .min60
        #expect(s.hasMigratedToNativeCloudKit == true)
    }

    @Test func passiveMapsToOff() async throws {
        let c = try container()
        let (s, d) = settings("mig-b")
        d.set(true, forKey: "settings.isPassiveDevice")
        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: tempStore())
        #expect(s.updateInterval == .off)
    }

    @Test func isIdempotent() async throws {
        let c = try container()
        let (s, _) = settings("mig-c")
        let store = tempStore()
        _ = await store.storeData(Data([1]), ext: "png")
        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: store)
        let countAfterFirst = try c.mainContext.fetch(FetchDescriptor<StoredImage>()).count
        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: store)
        #expect(try c.mainContext.fetch(FetchDescriptor<StoredImage>()).count == countAfterFirst)
    }
}
