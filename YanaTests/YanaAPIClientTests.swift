import Foundation
import Testing
@testable import Yana

@Suite("YanaAPIClient")
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

    @Test func decodesAServerErrorEnvelopeOn404() async {
        let body = #"{"error":{"code":"not_found","message":"Article not found."}}"#.data(using: .utf8)!
        let client = mockClient(status: 404, body: body)
        struct Empty: Decodable {}
        await #expect(throws: YanaAPIClientError.server(YanaAPIError(code: "not_found", message: "Article not found."))) {
            let _: Empty = try await client.get("/api/v1/articles/999")
        }
    }

    @Test func decodesASuccessfulResponse() async throws {
        struct Feeds: Decodable, Equatable { let feeds: [String] }
        let body = #"{"feeds":[]}"#.data(using: .utf8)!
        let client = mockClient(status: 200, body: body)
        let result: Feeds = try await client.get("/api/v1/feeds")
        #expect(result == Feeds(feeds: []))
    }

    @Test func attachesTheBearerToken() async throws {
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

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let stub = Self.stub else { return }
        let (response, data) = stub(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
