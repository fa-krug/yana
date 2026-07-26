import Testing
import SwiftData
import Foundation
@testable import Yana

/// Verifies that the SwiftData model schema is compatible with CloudKit mirroring.
///
/// CloudKit mirroring (`cloudKitDatabase: .automatic`) requires:
///   - All attributes are optional or have default values
///   - All relationships are optional (arrays must be `[T]?`, not `[T] = []`) with inverses
///   - No `#Unique` constraints (CloudKit has no equivalent)
///
/// **CURRENT STATUS — BLOCKED**: as of 2026-07-26 this test fails with the validation error:
///
///     CloudKit integration requires that all relationships be optional, the following are not:
///     Article: tags
///     Feed: articles
///     Feed: tags
///     Tag: articles
///     Tag: feeds
///
/// The fix is to change those declarations from `[T] = []` to `[T]?` in each model, then
/// re-enable `.automatic` in `AppContainer.shared` (currently reverted to `.none`).
///
/// Note: This test requires a persistent (on-disk) store — `.automatic` is incompatible
/// with in-memory stores. The container is created in a unique temp directory and cleaned
/// up in a `defer` block.
///
/// Environmental note: In the simulator without an iCloud account, CloudKit may log
/// account-not-available warnings, but schema validation is local — it does not require a
/// network round-trip or iCloud sign-in.
@MainActor
struct CloudKitSchemaCompatibilityTests {

    @Test func automaticContainerInitializesWithoutThrowing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = ModelConfiguration(url: url, cloudKitDatabase: .automatic)

        // If any model violates CloudKit's rules (non-optional relationship, #Unique constraint,
        // an attribute with neither default nor optional marker), this init throws — the test
        // then fails loudly with the exact validation error message.
        //
        // CURRENTLY FAILS because Feed.articles, Feed.tags, Tag.articles, Tag.feeds, and
        // Article.tags are non-optional array relationships. Fix: declare them as [T]?.
        _ = try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: config
        )
    }
}
