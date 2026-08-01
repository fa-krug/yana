import Foundation
import SwiftData

/// Registers `StoredImage` rows in its own background `ModelContext`. Separate from the callers'
/// contexts because the scan reads every existing row and the inserts carry whole image blobs —
/// work that must not land on the main actor.
@ModelActor
actor StoredImageRegistrar {
    /// Insert a row for each hash that has bytes on disk but no row yet. Returns how many it added.
    func register(hashes: Set<String>, imageStore: ImageStore) async -> Int {
        let existing = Set((try? modelContext.fetch(FetchDescriptor<StoredImage>()))?.map(\.contentHash) ?? [])
        var inserted = 0
        for hash in hashes where !existing.contains(hash) {
            guard let bytes = await imageStore.rawData(forHash: hash) else { continue }
            let ext = await imageStore.recordedExt(forHash: hash)
            modelContext.insert(StoredImage(contentHash: hash, data: bytes, ext: ext))
            inserted += 1
        }
        if inserted > 0 { try? modelContext.save() }
        return inserted
    }
}

/// Bridges the on-disk `ImageStore` cache and the synced `StoredImage` SwiftData rows.
/// `ImageStore` stays the fast path for the reader; `StoredImage` is the synced source of truth.
enum ImageSync {
    /// Insert a `StoredImage` for each hash that has bytes on disk but no row yet. Called from the
    /// aggregation write path (after upserts) so every image an article references gets mirrored.
    ///
    /// Takes a `ModelContainer`, not a `ModelContext`, so the work can run off the main actor:
    /// `StoredImageRegistrar` is a `@ModelActor` and a `@ModelActor` executes on its **caller's**
    /// thread, so the hop through `OffMainActor` is what actually keeps the scan and the blob
    /// inserts off the main thread.
    static func ensureStored(hashes: Set<String>, container: ModelContainer, imageStore: ImageStore) async {
        guard !hashes.isEmpty else { return }
        await OffMainActor.run {
            _ = await StoredImageRegistrar(modelContainer: container)
                .register(hashes: hashes, imageStore: imageStore)
        }
    }

    /// Ensure the disk cache has bytes for `hash`. If the file is missing but a synced `StoredImage`
    /// exists (arrived from another device), write the blob to the cache. Returns whether bytes are
    /// on disk afterwards.
    ///
    /// Stays on the caller's context: this is a single indexed-by-predicate row fetch driven by a
    /// reader cache miss, and the reader needs the answer on the main actor anyway.
    @MainActor
    static func materialize(hash: String, context: ModelContext, imageStore: ImageStore) async -> Bool {
        if await imageStore.fileExists(forHash: hash) { return true }
        let descriptor = FetchDescriptor<StoredImage>(predicate: #Predicate { $0.contentHash == hash })
        guard let stored = (try? context.fetch(descriptor))?.first else { return false }
        _ = await imageStore.storeData(stored.data, ext: stored.ext)

        return true
    }
}
