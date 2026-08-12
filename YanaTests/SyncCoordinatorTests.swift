import Foundation
import Testing
@testable import Yana

/// `SyncCoordinator` is what stops two `SyncEngine.sync()` calls from ever racing the same
/// `ModelContainer` and producing duplicate `Article` rows (see its doc comment and
/// `DuplicateArticleCleanupTests`). These tests drive it with plain async closures rather than a
/// real network-backed `SyncEngine`, since the coordinator itself is generic over the operation.
@MainActor
@Suite("SyncCoordinator")
struct SyncCoordinatorTests {
    @Test func neverRunsTwoQueuedOperationsConcurrently() async throws {
        let coordinator = SyncCoordinator()
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await coordinator.run { () async throws -> Int in
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await tracker.exit()
                        return 0
                    }
                }
            }
        }

        #expect(await tracker.maxConcurrent == 1)
    }

    @Test func eachCallerGetsItsOwnResultNotAnotherCallersInFlightOne() async throws {
        let coordinator = SyncCoordinator()

        let results = await withTaskGroup(of: (Int, Int).self) { group in
            group.addTask {
                let value = (try? await coordinator.run { () async throws -> Int in
                    try? await Task.sleep(for: .milliseconds(20))
                    return 1
                }) ?? -1
                return (0, value)
            }
            group.addTask {
                let value = (try? await coordinator.run { () async throws -> Int in 2 }) ?? -1
                return (1, value)
            }
            var collected: [Int: Int] = [:]
            for await (index, value) in group { collected[index] = value }
            return collected
        }

        #expect(results[0] == 1)
        #expect(results[1] == 2)
    }

    @Test func aFailedOperationDoesNotBlockLaterQueuedOnes() async throws {
        struct TestError: Error {}
        let coordinator = SyncCoordinator()

        do {
            _ = try await coordinator.run { () async throws -> Int in throw TestError() }
            Issue.record("expected the operation to throw")
        } catch is TestError {
            // Expected.
        }

        let succeeding = try await coordinator.run { () async throws -> Int in 42 }
        #expect(succeeding == 42)
    }
}

private actor ConcurrencyTracker {
    private(set) var maxConcurrent = 0
    private var current = 0

    func enter() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func exit() {
        current -= 1
    }
}
