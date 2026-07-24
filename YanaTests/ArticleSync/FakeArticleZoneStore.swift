import Foundation
@testable import Yana

/// In-memory `ArticleZoneStore`. `articles` is keyed by UID; `images` by hash (write-once —
/// re-adding an existing hash is a no-op, proving image dedup). `pendingChanges` is what the next
/// `fetchChanges()` returns (simulating remote deltas).
@MainActor
final class FakeArticleZoneStore: ArticleZoneStore {
    var pendingChanges = ArticleZoneChanges.empty
    private(set) var articles: [String: SyncedArticleRecord] = [:]
    private(set) var images: [String: SyncedImageRecord] = [:]
    private(set) var deletedUIDs: [String] = []
    private(set) var uploadedImageHashes: [String] = []

    func fetchChanges() async throws -> ArticleZoneChanges {
        let changes = pendingChanges
        pendingChanges = .empty
        return changes
    }

    func upsert(articles newArticles: [SyncedArticleRecord], images newImages: [SyncedImageRecord]) async throws {
        for record in newArticles { articles[record.uid] = record }
        for image in newImages where images[image.hash] == nil {
            images[image.hash] = image
            uploadedImageHashes.append(image.hash)
        }
    }

    func delete(articleUIDs: [String]) async throws {
        for uid in articleUIDs { articles[uid] = nil; deletedUIDs.append(uid) }
    }

    func fetchImage(hash: String) async throws -> SyncedImageRecord? { images[hash] }

    /// Seed a record as if it already lived remotely (used to prime `pendingChanges`).
    func seedRemote(_ record: SyncedArticleRecord) {
        articles[record.uid] = record
        pendingChanges.articles.append(record)
    }
}
