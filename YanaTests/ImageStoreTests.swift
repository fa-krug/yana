import Foundation
import Testing
@testable import Yana

@Suite("ImageStore fetch-by-hash")
struct ImageStoreTests {
    private func stubClient(bytes: Data, contentType: String) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
            return (response, bytes)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    // Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- the shared static
    // `MockURLProtocol.stub` races across suites Swift Testing schedules concurrently (see
    // `MockURLProtocol.swift`/task-10-report.md).

    @Test func fetchesAndCachesOnMiss() async throws {
        await MockURLProtocol.lock.withLock {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = ImageStore(directory: tempDir)
            let client = stubClient(bytes: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")

            let fetched = await store.fetchIfNeeded(hash: "abc123", client: client)
            #expect(fetched)
            #expect(await store.fileExists(forHash: "abc123"))
        }
    }

    @Test func doesNotRefetchWhenAlreadyOnDisk() async throws {
        await MockURLProtocol.lock.withLock {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = ImageStore(directory: tempDir)
            _ = await store.storeData(Data([0x01]), ext: "jpg")
            let hash = ImageStore.hashForTesting(Data([0x01]))

            var requestCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                requestCount += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let fetched = await store.fetchIfNeeded(hash: hash, client: client)
            #expect(fetched)
            #expect(requestCount == 0)
        }
    }

    /// `getRaw` deliberately doesn't check the status code itself (its callers decide), so
    /// `fetchIfNeeded` must -- a 404 for a stale/GC'd hash, or a transient 5xx, must not get
    /// written to disk verbatim: that would permanently poison the cache, since every later
    /// `fileExists(forHash:)` would then report true forever with no way to retry the real fetch.
    @Test func nonSuccessStatusDoesNotCacheAndReturnsFalse() async throws {
        await MockURLProtocol.lock.withLock {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = ImageStore(directory: tempDir)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"not_found","message":"no such image"}}"#.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let fetched = await store.fetchIfNeeded(hash: "missing456", client: client)
            #expect(fetched == false)
            #expect(await store.fileExists(forHash: "missing456") == false)
        }
    }
}
