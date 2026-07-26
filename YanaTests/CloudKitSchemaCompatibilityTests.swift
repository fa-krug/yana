import Testing
import SwiftData
import Foundation
@testable import Yana

/// Guards that all four SwiftData models (`Feed`, `Tag`, `Article`, `StoredImage`) remain
/// compatible with CloudKit mirroring (`cloudKitDatabase: .automatic`).
///
/// CloudKit mirroring requires:
///   - All attributes are optional or have default values
///   - All relationships are optional (`[T]?`, not `[T] = []`) with inverses
///   - No `#Unique` constraints (CloudKit has no equivalent)
///
/// If any model violates these rules — e.g. a non-optional array relationship is added or
/// a `#Unique` macro is introduced — `ModelContainer` init throws with an exact validation
/// error message and this test fails loudly, catching the regression before it ships.
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
        _ = try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: config
        )
    }
}
