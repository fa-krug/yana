import Foundation
import Testing
@testable import Yana

/// A tiny main-actor counter the coalescer's action mutates, so tests can assert how many times
/// the (coalesced) action actually ran.
@MainActor
private final class RunCounter {
    private(set) var runs = 0
    private(set) var maxConcurrent = 0
    private var active = 0

    /// Increment the run count and, while awaiting `body`, track the peak number of overlapping
    /// runs — used to prove single-flight (peak must stay 1).
    func run(_ body: () async -> Void = {}) async {
        runs += 1
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        await body()
        active -= 1
    }
}

@MainActor
@Suite("TrailingCoalescer")
struct TrailingCoalescerTests {
    @Test func burstOfSchedulesCollapsesToOneRun() async throws {
        let counter = RunCounter()
        let coalescer = TrailingCoalescer(interval: .milliseconds(50)) { await counter.run() }

        for _ in 0..<8 { coalescer.schedule() }          // rapid burst within the quiet window
        try await Task.sleep(for: .milliseconds(250))    // let the trailing timer fire

        #expect(counter.runs == 1)
    }

    @Test func neverRunsConcurrentlyAndReRunsWhenTriggeredMidRun() async throws {
        let counter = RunCounter()
        // Each run holds for 100ms, so a schedule() landing mid-run exercises the single-flight path.
        let coalescer = TrailingCoalescer(interval: .milliseconds(30)) {
            await counter.run { try? await Task.sleep(for: .milliseconds(100)) }
        }

        coalescer.schedule()                              // fires ~30ms, runs until ~130ms
        try await Task.sleep(for: .milliseconds(60))      // ~60ms: first run is in flight
        coalescer.schedule()                              // trigger during the run → one trailing re-run
        try await Task.sleep(for: .milliseconds(300))     // let both runs drain

        #expect(counter.runs == 2)                        // in-flight run + exactly one trailing run
        #expect(counter.maxConcurrent == 1)               // never overlapped
    }

    @Test func fireNowRunsImmediatelyWithoutWaitingForDebounce() async throws {
        let counter = RunCounter()
        let coalescer = TrailingCoalescer(interval: .seconds(10)) { await counter.run() }

        await coalescer.fireNow()

        #expect(counter.runs == 1)
    }

    @Test func scheduleAfterRunTriggersAnotherRun() async throws {
        let counter = RunCounter()
        let coalescer = TrailingCoalescer(interval: .milliseconds(40)) { await counter.run() }

        coalescer.schedule()
        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.runs == 1)

        coalescer.schedule()                              // a fresh burst after quiet runs again
        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.runs == 2)
    }
}
