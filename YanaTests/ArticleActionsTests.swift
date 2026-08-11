import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleActions", .serialized)
struct ArticleActionsTests {
    // Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- `.serialized` above
    // only orders tests within THIS suite; it does nothing against other suites (e.g.
    // `YanaAPIClientTests`, `SyncEngineTests`) that share the same static `MockURLProtocol.stub`
    // and which Swift Testing schedules concurrently by default. See `MockURLProtocol.swift`.
    private func stubClient(pathsToResponses: [String: (Data, Int)]) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let (data, status) = pathsToResponses[key] ?? (Data(), 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func setStarredSendsAPatchWithTheBooleanBody() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(pathsToResponses: [
                "PATCH /api/v1/articles/100": (#"{"id":100,"starred":true}"#.data(using: .utf8)!, 200)
            ])
            let actions = ArticleActions(client: client)
            try await actions.setStarred(true, articleServerID: 100)
        }
    }

    @Test func reloadPostsAndReturnsTheJobId() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(pathsToResponses: [
                "POST /api/v1/articles/100/reload": (#"{"jobId":1}"#.data(using: .utf8)!, 202)
            ])
            let actions = ArticleActions(client: client)
            let jobID = try await actions.reload(articleServerID: 100)
            #expect(jobID == 1)
        }
    }

    @Test func updateAllPostsToAggregate() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(pathsToResponses: [
                "POST /api/v1/aggregate": (#"{"runId":5}"#.data(using: .utf8)!, 202)
            ])
            let actions = ArticleActions(client: client)
            let runID = try await actions.updateAll()
            #expect(runID == 5)
        }
    }

    @Test func setReadingPositionSendsAPatchAndReturnsUpdatedAt() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(pathsToResponses: [
                "PATCH /api/v1/reading-position": (#"{"articleId":100,"updatedAt":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!, 200)
            ])
            let actions = ArticleActions(client: client)
            let updatedAt = try await actions.setReadingPosition(articleServerID: 100)
            #expect(updatedAt == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        }
    }
}
