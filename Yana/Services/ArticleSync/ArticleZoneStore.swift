import Foundation

/// Abstraction over the CloudKit `Articles` zone so `ArticleSyncService` is unit-testable without
/// CloudKit. The production adapter (`CloudKitArticleZoneStore`) wraps `CKSyncEngine`; tests use a
/// `FakeArticleZoneStore`.
protocol ArticleZoneStore: Sendable {
    /// Drain remote changes accumulated since the last call (upserts + tombstones).
    func fetchChanges() async throws -> ArticleZoneChanges
    /// Upsert article records and (write-once) image blobs.
    func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws
    /// Delete article records by UID (tombstone).
    func delete(articleUIDs: [String]) async throws
    /// Fetch a single image blob by hash, or nil when absent.
    func fetchImage(hash: String) async throws -> SyncedImageRecord?
}
