import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct StoredImageTests {
    private func container() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: config)
    }

    @Test func insertsAndFetchesByHash() throws {
        let c = try container()
        c.mainContext.insert(StoredImage(contentHash: "abc", data: Data([1,2,3]), ext: "jpg"))
        try c.mainContext.save()
        let rows = try c.mainContext.fetch(FetchDescriptor<StoredImage>(
            predicate: #Predicate { $0.contentHash == "abc" }))
        #expect(rows.count == 1)
        #expect(rows.first?.data == Data([1,2,3]))
        #expect(rows.first?.ext == "jpg")
    }
}
