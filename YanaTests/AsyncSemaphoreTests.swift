import Foundation
import Testing
@testable import Yana

@Suite("AsyncSemaphore")
struct AsyncSemaphoreTests {

    /// Tracks the peak number of tasks inside the critical section at once.
    private actor ConcurrencyTracker {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    // Many tasks contend for a 3-slot gate; no more than 3 are ever inside at once.
    @Test func boundsConcurrencyToLimit() async {
        let gate = AsyncSemaphore(limit: 3)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await gate.acquire()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 500_000)
                    await tracker.leave()
                    gate.release()
                }
            }
        }
        let peak = await tracker.peak
        #expect(peak >= 1)
        #expect(peak <= 3)
    }

    // A single-slot gate serializes: the second acquire only proceeds after the first releases.
    @Test func singleSlotSerializes() async {
        let gate = AsyncSemaphore(limit: 1)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await gate.acquire()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 200_000)
                    await tracker.leave()
                    gate.release()
                }
            }
        }
        #expect(await tracker.peak == 1)
    }
}
