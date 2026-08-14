import Foundation

private struct StarredBody: Encodable { let starred: Bool }
private struct StarredResponse: Decodable { let id: Int; let starred: Bool }
private struct ReadBody: Encodable { let read: Bool }
private struct ReadResponse: Decodable { let id: Int; let read: Bool }
private struct ReloadResponse: Decodable { let jobId: Int }
private struct AggregateResponse: Decodable { let runId: Int }
private struct ReadingPositionBody: Encodable { let articleId: Int }

/// Thin façade over the article-mutating parts of the API, so UI code doesn't construct
/// `YanaAPIClient` calls inline. Read paths (sync, content, feeds) live in `SyncEngine` instead --
/// this is specifically the user-initiated write/trigger surface.
///
/// Every method here only sends a request and decodes its ack -- it never touches the local
/// SwiftData mirror itself. `setStarred`'s ack does carry the new value back, but callers still
/// own writing it locally (this type has no `ModelContext`); `reload`/`updateAll` only trigger
/// server-side work, returning a job/run id callers hand to `UpdateAndSync` to actually observe
/// completion and pull results down -- neither ack is new content itself.
@MainActor
final class ArticleActions {
    private let client: YanaAPIClient

    init(client: YanaAPIClient) {
        self.client = client
    }

    func setStarred(_ starred: Bool, articleServerID: Int) async throws {
        let _: StarredResponse = try await client.patch("/api/v1/articles/\(articleServerID)", body: StarredBody(starred: starred))
    }

    func setRead(_ read: Bool, articleServerID: Int) async throws {
        let _: ReadResponse = try await client.patch("/api/v1/articles/\(articleServerID)", body: ReadBody(read: read))
    }

    /// Returns the server's `jobId` for this reload -- `UpdateAndSync.pollForReloadedContent`
    /// needs it to pick this job's own completion event out of the shared `/jobs/events` stream
    /// (every reload/aggregate job for this user is multiplexed onto that one stream).
    @discardableResult
    func reload(articleServerID: Int) async throws -> Int {
        let response: ReloadResponse = try await client.post("/api/v1/articles/\(articleServerID)/reload")
        return response.jobId
    }

    @discardableResult
    func updateAll() async throws -> Int {
        let response: AggregateResponse = try await client.post("/api/v1/aggregate")
        return response.runId
    }

    /// Sets the account's shared reading position (the article every paired device converges on --
    /// see `ReadingPositionSync`). Returns the server-stamped `updatedAt`, used for the
    /// last-writer-wins comparison `SyncEngine.syncReadingPosition` makes against a later pull.
    @discardableResult
    func setReadingPosition(articleServerID: Int) async throws -> Date? {
        let response: ReadingPositionWire = try await client.patch(
            "/api/v1/reading-position", body: ReadingPositionBody(articleId: articleServerID)
        )
        return response.updatedAt
    }
}
