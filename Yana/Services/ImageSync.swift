import Foundation
import SwiftData

/// Bridges the on-disk `ImageStore` cache and the synced `StoredImage` SwiftData rows.
/// `ImageStore` stays the fast path for the reader; `StoredImage` is the synced source of truth.
enum ImageSync {
    /// Insert a `StoredImage` for each hash that has bytes on disk but no row yet. Called from the
    /// aggregation write path (after upserts) so every image an article references gets mirrored.
    @MainActor
    static func ensureStored(hashes: Set<String>, context: ModelContext, imageStore: ImageStore) async {
        guard !hashes.isEmpty else { return }
        let existing = Set((try? context.fetch(FetchDescriptor<StoredImage>()))?.map(\.hash) ?? [])
        var inserted = false
        for hash in hashes where !existing.contains(hash) {
            guard let bytes = await imageStore.rawData(forHash: hash) else { continue }
            let ext = await imageStore.recordedExt(forHash: hash)
            context.insert(StoredImage(hash: hash, data: bytes, ext: ext))
            inserted = true
        }
        if inserted { try? context.save() }
    }

    /// Ensure the disk cache has bytes for `hash`. If the file is missing but a synced `StoredImage`
    /// exists (arrived from another device), write the blob to the cache. Returns whether bytes are
    /// on disk afterwards.
    @MainActor
    static func materialize(hash: String, context: ModelContext, imageStore: ImageStore) async -> Bool {
        if await imageStore.fileExists(forHash: hash) { return true }
        let descriptor = FetchDescriptor<StoredImage>(predicate: #Predicate { $0.hash == hash })
        guard let stored = (try? context.fetch(descriptor))?.first else { return false }
        _ = await imageStore.storeData(stored.data, ext: stored.ext)
        return true
    }
}
