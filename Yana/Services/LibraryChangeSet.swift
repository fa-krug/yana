import Foundation
import SwiftData

/// The `Article` rows a single `ModelContextDidSave` touched.
///
/// `ModelContext.didSave` carries `inserted` / `updated` / `deleted` arrays of
/// `PersistentIdentifier`, which is what lets `ArticleStore` refresh only the rows that changed
/// instead of re-reading the whole library. Everything not an `Article` is dropped here: feed-logo
/// resolution, tag edits, and `StoredImage` registration all save, and none of them change the
/// timeline, so they must not cost a re-index.
///
/// Pure and `Sendable`, so the parsing is unit-tested without SwiftData or a live store.
struct LibraryChangeSet: Sendable, Equatable {
    /// Rows that need re-reading — inserts and updates, which are handled identically.
    var changed: [PersistentIdentifier] = []
    /// Rows that are gone from the store and must be dropped from the index.
    var deleted: [PersistentIdentifier] = []

    var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }
    var count: Int { changed.count + deleted.count }

    /// SwiftData's entity name for `Article` — the discriminator in a `PersistentIdentifier`.
    static let articleEntityName = "\(Article.self)"

    init(changed: [PersistentIdentifier] = [], deleted: [PersistentIdentifier] = []) {
        self.changed = changed
        self.deleted = deleted
    }

    /// Parse a `ModelContext.didSave` payload, keeping only `Article` rows.
    ///
    /// A row appearing in both `inserted` and `updated` (SwiftData reports relationship writes in
    /// both) is counted once; a row that was inserted *and* deleted in the same save counts only as
    /// deleted, since that is the state the store ends in.
    init(userInfo: [AnyHashable: Any]?) {
        func articles(_ key: String) -> [PersistentIdentifier] {
            let ids = userInfo?[key] as? [PersistentIdentifier] ?? []
            return ids.filter { $0.entityName == Self.articleEntityName }
        }
        let deleted = articles("deleted")
        let deletedSet = Set(deleted)
        var seen = Set<PersistentIdentifier>()
        let changed = (articles("inserted") + articles("updated")).filter {
            !deletedSet.contains($0) && seen.insert($0).inserted
        }
        self.init(changed: changed, deleted: deleted)
    }

    /// Fold another save's changes in, so a burst collapses into one refresh.
    mutating func formUnion(_ other: LibraryChangeSet) {
        let deletedSet = Set(deleted).union(other.deleted)
        var seen = Set<PersistentIdentifier>()
        changed = (changed + other.changed).filter {
            !deletedSet.contains($0) && seen.insert($0).inserted
        }
        deleted = Array(deletedSet)
    }
}
