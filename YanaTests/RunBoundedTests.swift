import Testing
@testable import Yana

/// Thread-safe counter for tracking concurrent in-flight work and the high-water mark reached.
/// A plain `actor` (not a lock) since the whole point here is to observe genuine `Task`
/// concurrency via `await`, not to serialize access from the outside.
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    private(set) var totalStarted = 0
    private(set) var totalFinished = 0

    func enter() {
        current += 1
        totalStarted += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
        totalFinished += 1
    }
}

/// Direct tests of `SyncEngine.swift`'s `runBounded` helper -- the sliding-window
/// `withTaskGroup` that backs `backfillMissingContent`'s bounded-concurrency content fetch.
/// Deliberately independent of any HTTP mocking: `SyncEngineTests`' end-to-end tests prove the
/// final *result* is correct, but since a mocked HTTP call responds essentially instantly, that
/// alone can't distinguish "correctly bounded to N concurrent tasks" from "accidentally fully
/// serial" or "accidentally unbounded" -- both would still produce the right final data. These
/// tests use a real `Task.sleep` to make overlapping execution actually observable.
@Suite("runBounded")
struct RunBoundedTests {
    /// The core claim: with far more items (30) than the concurrency limit (5), the number of
    /// tasks *actually running at once* never exceeds 5, but DOES reach exactly 5 -- not some
    /// accidentally-lower number, which would indicate the sliding window isn't refilling a
    /// finished slot promptly.
    @Test func neverExceedsTheConcurrencyLimitAndActuallyReachesIt() async {
        let tracker = ConcurrencyTracker()
        let items = Array(0..<30)

        await runBounded(items, maxConcurrency: 5) { _ in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            await tracker.exit()
        }

        let peak = await tracker.peak
        let started = await tracker.totalStarted
        let finished = await tracker.totalFinished
        #expect(peak <= 5, "concurrency bound was exceeded: peak=\(peak)")
        #expect(peak == 5, "expected the sliding window to actually reach the limit; peak=\(peak)")
        #expect(started == 30, "expected every item to run exactly once; started=\(started)")
        #expect(finished == 30, "a task leaked without finishing; finished=\(finished)")
    }

    /// Fewer items than the concurrency limit: the bound is a ceiling, not a floor -- peak
    /// concurrency should equal the item count, not the (larger) limit.
    @Test func fewerItemsThanTheLimitRunsAllOfThemWithoutOverLaunching() async {
        let tracker = ConcurrencyTracker()
        let items = Array(0..<3)

        await runBounded(items, maxConcurrency: 10) { _ in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await tracker.exit()
        }

        let peak = await tracker.peak
        let started = await tracker.totalStarted
        #expect(peak == 3)
        #expect(started == 3)
    }

    /// Every item's work runs exactly once -- no duplicate dispatch, no drop -- across a count
    /// that doesn't divide evenly by the concurrency limit (31 / 4), exactly the shape that would
    /// expose an off-by-one in the "refill on completion" loop.
    @Test func processesEveryItemExactlyOnceWithAnUnevenRemainder() async {
        actor SeenIDs {
            private var ids: [Int] = []
            func record(_ id: Int) { ids.append(id) }
            var all: [Int] { ids }
        }
        let seen = SeenIDs()
        let items = Array(0..<31)

        await runBounded(items, maxConcurrency: 4) { id in
            try? await Task.sleep(nanoseconds: 1_000_000)
            await seen.record(id)
        }

        let all = await seen.all
        #expect(all.count == 31)
        #expect(Set(all) == Set(0..<31))
    }

    @Test func emptyItemsDoesNothing() async {
        let tracker = ConcurrencyTracker()
        await runBounded([Int](), maxConcurrency: 5) { _ in await tracker.enter() }
        let started = await tracker.totalStarted
        #expect(started == 0)
    }

    /// A per-item failure (`SyncEngine`'s real closure catches internally rather than throwing,
    /// since `work`'s signature is non-throwing) must not abort the rest of the batch -- every
    /// other item should still run to completion.
    @Test func aFailingItemDoesNotAbortTheRestOfTheBatch() async {
        let tracker = ConcurrencyTracker()
        let items = Array(0..<10)

        await runBounded(items, maxConcurrency: 3) { id in
            await tracker.enter()
            // Model a per-item failure as "notices an error and returns early" -- `work` can't
            // literally throw here, matching the real call site.
            if id % 3 == 0 {
                await tracker.exit()
                return
            }
            await tracker.exit()
        }

        let started = await tracker.totalStarted
        let finished = await tracker.totalFinished
        #expect(started == 10)
        #expect(finished == 10)
    }
}
