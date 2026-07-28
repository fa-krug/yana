import Foundation
import Testing
@testable import Yana

/// Each test builds its own `LibraryRevision` against a private `NotificationCenter` (never
/// `.default`) with a short coalescing interval, so these run fast and never race the real
/// `.NSPersistentStoreRemoteChange` traffic other suites post to the shared center — the same
/// concern `ArticleStoreIncrementalTests` documents for `.NSPersistentStoreRemoteChange` firing
/// several times per local save.
@MainActor
@Suite("LibraryRevision")
struct LibraryRevisionTests {
    private func post(_ center: NotificationCenter) {
        center.post(name: .NSPersistentStoreRemoteChange, object: nil)
    }

    @Test func burstOfRemoteChangesBumpsTokenOnce() async throws {
        let center = NotificationCenter()
        let revision = LibraryRevision(center: center, interval: .milliseconds(50))
        revision.startObserving()

        for _ in 0..<8 { post(center) }               // rapid burst within the quiet window
        try await Task.sleep(for: .milliseconds(250))  // let the trailing timer fire

        #expect(revision.token == 1)
    }

    @Test func laterSeparateBurstBumpsTokenAgain() async throws {
        let center = NotificationCenter()
        let revision = LibraryRevision(center: center, interval: .milliseconds(50))
        revision.startObserving()

        for _ in 0..<5 { post(center) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(revision.token == 1)

        for _ in 0..<5 { post(center) }                // a fresh burst after the quiet period
        try await Task.sleep(for: .milliseconds(200))
        #expect(revision.token == 2)
    }

    @Test func startObservingIsIdempotent() async throws {
        let center = NotificationCenter()
        let revision = LibraryRevision(center: center, interval: .milliseconds(50))
        revision.startObserving()
        revision.startObserving()  // second call must not register a second observer

        post(center)
        try await Task.sleep(for: .milliseconds(200))

        #expect(revision.token == 1)  // would be 2 if the observer had been registered twice
    }

    @Test func noNotificationsMeansNoBump() async throws {
        let center = NotificationCenter()
        let revision = LibraryRevision(center: center, interval: .milliseconds(50))
        revision.startObserving()

        try await Task.sleep(for: .milliseconds(150))

        #expect(revision.token == 0)
    }
}
