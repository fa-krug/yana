#if DEBUG
import CoreData
import SwiftData
import Foundation

/// DEBUG-only. Pushes the SwiftData-derived CloudKit schema to the container's **Development**
/// environment so every field (including optionals) exists server-side and records sync fully during
/// development. SwiftData does not expose `initializeCloudKitSchema()`, so this builds a parallel
/// `NSPersistentCloudKitContainer` over the same managed object model and initializes the schema
/// there (technique: fatbobman.com). Runs against a THROWAWAY temp store — the schema is derived from
/// the MODEL, not the data. Requires a signed-in iCloud account; on any failure it logs and returns
/// (never fatal).
///
/// **Called synchronously from the `AppContainer.shared` initializer, BEFORE the live `.automatic`
/// container is created**, so it runs on every development launch and always pushes the current
/// schema. Ordering is load-bearing: this points a temporary `NSPersistentCloudKitContainer` at the
/// SAME CloudKit container (`iCloud.de.fa-krug.Yana`) the app mirrors to, and a process may host only
/// one mirroring container per CloudKit container. `run()` tears its container fully down
/// (`remove(store)`) before returning, and only then does `AppContainer.shared` build the live
/// container — so the two are never alive at once. Running it concurrently with the live store (e.g.
/// from a detached launch task) crashes the app on a signed-in device.
///
/// Uses `NSLog` because `os_log`
/// output does not surface from a locally built/run Mac Catalyst app (same reason DebugSeed/the old
/// schema bootstrap used NSLog). NEVER ship in production: it is an expensive network operation and is
/// compiled out of release builds.
enum CloudKitSchemaInitializer {
    static let containerIdentifier = "iCloud.de.fa-krug.Yana"

    /// Build/refresh the Development schema. Synchronous and blocking (network); it must complete and
    /// remove its temporary store before the live `AppContainer.shared` container is created (see the
    /// type doc — that ordering is what prevents two mirroring containers on one CloudKit container).
    static func run() {
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(
            for: [Feed.self, Tag.self, Article.self, StoredImage.self]
        ) else {
            NSLog("CloudKitSchemaInitializer: could not build managed object model")
            SyncLog.shared.error("Could not build managed object model", category: "Schema")
            return
        }

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yana-ckschema-\(UUID().uuidString).store")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.cloudKitContainerOptions =
            NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        // Synchronous load so the schema init runs in a deterministic order.
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: "YanaSchemaInit", managedObjectModel: mom)
        container.persistentStoreDescriptions = [description]

        let box = LoadResult()
        container.loadPersistentStores { _, error in box.error = error }
        if let error = box.error {
            NSLog("CloudKitSchemaInitializer: store load failed: \(error.localizedDescription)")
            SyncLog.shared.error("Store load failed: \(error.localizedDescription)", category: "Schema")
            cleanup(storeURL)
            return
        }

        do {
            try container.initializeCloudKitSchema(options: [])
            NSLog("CloudKitSchemaInitializer: Development schema initialized for \(containerIdentifier)")
            SyncLog.shared.notice("Development schema initialized for \(containerIdentifier)", category: "Schema")
        } catch {
            NSLog("CloudKitSchemaInitializer: initializeCloudKitSchema failed: \(error.localizedDescription)")
            SyncLog.shared.error("initializeCloudKitSchema failed: \(error.localizedDescription)", category: "Schema")
        }

        // Release file locks on the throwaway store, then delete it and its WAL/SHM siblings.
        if let store = container.persistentStoreCoordinator.persistentStores.first {
            try? container.persistentStoreCoordinator.remove(store)
        }
        cleanup(storeURL)
    }

    /// Boxes the load error so the (escaping, synchronously-invoked) completion handler can write it
    /// without a mutable capture that trips Swift 6 concurrency checks.
    private final class LoadResult: @unchecked Sendable { var error: Error? }

    private static func cleanup(_ storeURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let sibling = storeURL.deletingLastPathComponent()
                .appendingPathComponent(storeURL.lastPathComponent + suffix)
            try? FileManager.default.removeItem(at: sibling)
        }
    }
}
#endif
