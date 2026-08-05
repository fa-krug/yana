import Foundation
@testable import Yana

/// Shared `URLProtocol` stub for tests that exercise `YanaAPIClient` over a real `URLSession`
/// without hitting the network. Originally defined independently in both
/// `YanaAPIClientTests.swift` (Task 1) and this task's `SyncEngineTests.swift`; consolidated here
/// since both live in the `YanaTests` target and a duplicate `final class` definition is a
/// compile error, not just a lint warning.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?

    /// `.serialized` on a `@Suite` only orders tests *within* that suite -- it does nothing for
    /// two DIFFERENT suites (e.g. `YanaAPIClientTests` and `SyncEngineTests`, both now sharing
    /// this one `stub`) racing on it when Swift Testing schedules their tests concurrently, which
    /// it does by default. Confirmed empirically in a standalone harness (see task-10-report.md):
    /// without this lock, running both suites together corrupts `stub` mid-request on essentially
    /// every run, even with `.serialized` on each suite individually. Every test that sets `stub`
    /// must wrap its whole body (set `stub`, make the call, assert) in
    /// `await MockURLProtocol.lock.withLock { ... }`. An `actor` would NOT fix this despite
    /// looking equivalent -- an actor yields to other callers across `await` points inside its
    /// own methods (reentrancy), which is exactly where the corruption would still happen;
    /// `AsyncSemaphore` (existing production utility, `Yana/Utilities/AsyncSemaphore.swift`) is a
    /// real non-reentrant lock backed by an explicit FIFO waiter queue, not actor reentrancy.
    static let lock = AsyncSemaphore(limit: 1)

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

extension AsyncSemaphore {
    /// `acquire()`/`release()` convenience for wrapping a whole async test body. `@MainActor`
    /// so a MainActor-isolated test body (e.g. `SyncEngineTests`, since `SyncEngine` itself is
    /// `@MainActor`) can pass its closure in without tripping Swift 6's `sending`-across-isolation
    /// check; a `nonisolated` caller (e.g. `YanaAPIClientTests`) can still call an async
    /// `@MainActor` method from anywhere, it just hops.
    @MainActor
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
