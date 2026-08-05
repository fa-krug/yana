import Foundation

private struct StarredBody: Encodable { let starred: Bool }
private struct StarredResponse: Decodable { let id: Int; let starred: Bool }
private struct ReloadResponse: Decodable { let jobId: Int }
private struct AggregateResponse: Decodable { let runId: Int }

/// Thin façade over the article-mutating parts of the API, so UI code doesn't construct
/// `YanaAPIClient` calls inline. Read paths (sync, content, feeds) live in `SyncEngine` instead --
/// this is specifically the user-initiated write/trigger surface.
///
/// Every method here only sends a request and decodes its ack -- it never touches the local
/// SwiftData mirror itself. `setStarred`'s ack does carry the new value back, but callers still
/// own writing it locally (this type has no `ModelContext`); `reload`/`updateAll` only trigger
/// server-side work and their response is just an ack with a job/run id, not new content, so
/// callers must follow up with a `SyncEngine.sync()` to actually pull results down.
@MainActor
final class ArticleActions {
    private let client: YanaAPIClient

    init(client: YanaAPIClient) {
        self.client = client
    }

    func setStarred(_ starred: Bool, articleServerID: Int) async throws {
        let _: StarredResponse = try await client.patch("/api/v1/articles/\(articleServerID)", body: StarredBody(starred: starred))
    }

    func reload(articleServerID: Int) async throws {
        let _: ReloadResponse = try await client.post("/api/v1/articles/\(articleServerID)/reload")
    }

    @discardableResult
    func updateAll() async throws -> Int {
        let response: AggregateResponse = try await client.post("/api/v1/aggregate")
        return response.runId
    }
}
