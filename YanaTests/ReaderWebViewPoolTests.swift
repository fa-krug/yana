import Testing
import WebKit
@testable import Yana

@MainActor
struct ReaderWebViewPoolTests {

    @Test func preloadFillsToMinimumDepth() {
        let pool = ReaderWebViewPool()
        pool.preload(minimumDepth: 3)
        #expect(pool.depth == 3)
    }

    @Test func preloadIsIdempotent() {
        let pool = ReaderWebViewPool()
        pool.preload(minimumDepth: 2)
        pool.preload(minimumDepth: 2)   // already full → no growth
        #expect(pool.depth == 2)
    }

    @Test func dequeueFromFilledPoolDropsDepthByOne() {
        let pool = ReaderWebViewPool()
        pool.preload(minimumDepth: 3)
        _ = pool.dequeue()
        // The refill is dispatched async to the main runloop, which this synchronous test never
        // returns to, so the reserve is observed one short.
        #expect(pool.depth == 2)
    }

    @Test func dequeueFromEmptyPoolStillReturnsAConfiguredView() {
        let pool = ReaderWebViewPool()
        let webView = pool.dequeue()
        // Shares the reader's process pool so pooled views run in the same Web Content process.
        #expect(webView.configuration.processPool === ReaderWebView.processPool)
    }

    @Test func drainEmptiesReserve() {
        let pool = ReaderWebViewPool()
        pool.preload(minimumDepth: 3)
        pool.drain()
        #expect(pool.depth == 0)
    }
}
