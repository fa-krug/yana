import Foundation

/// Placeholder production store; real `CKSyncEngine` implementation lands in Task 9.
@MainActor
final class CloudKitArticleZoneStore: ArticleZoneStore {
    func fetchChanges() async throws -> ArticleZoneChanges { .empty }
    func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws {}
    func delete(articleUIDs: [String]) async throws {}
    func fetchImage(hash: String) async throws -> SyncedImageRecord? { nil }
}
