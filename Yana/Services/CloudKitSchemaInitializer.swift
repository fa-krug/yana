#if DEBUG
import CoreData
import SwiftData
import Foundation

/// DEBUG-only. Pushes the SwiftData-derived CloudKit schema to the container's **Development**
/// environment so every field (including optionals) exists server-side and records sync fully during
/// development. SwiftData does not expose `initializeCloudKitSchema()`, so this builds a parallel
/// `NSPersistentCloudKitContainer` over the same managed object model and initializes the schema
/// there (technique: fatbobman.com). Runs against a THROWAWAY temp store — the schema is derived from
/// the MODEL, not the data — so it never contends with the live SwiftData store. Requires a signed-in
/// iCloud account; on any failure it logs and returns (never fatal). Uses `NSLog` because `os_log`
/// output does not surface from a locally built/run Mac Catalyst app (same reason DebugSeed/the old
/// schema bootstrap used NSLog). NEVER ship in production: it is an expensive network operation and is
/// compiled out of release builds.
enum CloudKitSchemaInitializer {
    static let containerIdentifier = "iCloud.de.fa-krug.Yana"

    /// Build/refresh the Development schema. Synchronous and blocking (network) — call OFF the launch
    /// path (e.g. from a background Task).
    static func run() {
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(
            for: [Feed.self, Tag.self, Article.self, StoredImage.self]
        ) else {
            NSLog("CloudKitSchemaInitializer: could not build managed object model")
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
            cleanup(storeURL)
            return
        }

        do {
            try container.initializeCloudKitSchema(options: [])
            NSLog("CloudKitSchemaInitializer: Development schema initialized for \(containerIdentifier)")
        } catch {
            NSLog("CloudKitSchemaInitializer: initializeCloudKitSchema failed: \(error.localizedDescription)")
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
