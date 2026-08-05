import Foundation
import Testing
@testable import Yana

@Suite("YanaAPIClient", .serialized)
struct YanaAPIClientTests {
    private func mockClient(status: Int, body: Data, session: URLSession? = nil) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "test-token", session: URLSession(configuration: config))
    }

    // Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- `.serialized` above
    // only orders tests within THIS suite; it does nothing against `SyncEngineTests`, a different
    // suite that shares the same static `MockURLProtocol.stub` and which Swift Testing schedules
    // concurrently with this one by default. See `MockURLProtocol.swift` for why an `actor`
    // wouldn't be enough and confirmed empirically in task-10-report.md.

    @Test func decodesAServerErrorEnvelopeOn404() async throws {
        try await MockURLProtocol.lock.withLock {
            let body = #"{"error":{"code":"not_found","message":"Article not found."}}"#.data(using: .utf8)!
            let client = mockClient(status: 404, body: body)
            struct Empty: Decodable {}
            await #expect(throws: YanaAPIClientError.server(YanaAPIError(code: "not_found", message: "Article not found."))) {
                let _: Empty = try await client.get("/api/v1/articles/999")
            }
        }
    }

    @Test func decodesASuccessfulResponse() async throws {
        try await MockURLProtocol.lock.withLock {
            struct Feeds: Decodable, Equatable { let feeds: [String] }
            let body = #"{"feeds":[]}"#.data(using: .utf8)!
            let client = mockClient(status: 200, body: body)
            let result: Feeds = try await client.get("/api/v1/feeds")
            #expect(result == Feeds(feeds: []))
        }
    }

    @Test func attachesTheBearerToken() async throws {
        try await MockURLProtocol.lock.withLock {
            var capturedAuth: String?
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "abc123", session: URLSession(configuration: config))
            struct Feeds: Decodable { let feeds: [String] }
            let _: Feeds = try await client.get("/api/v1/feeds")
            #expect(capturedAuth == "Bearer abc123")
        }
    }
}
