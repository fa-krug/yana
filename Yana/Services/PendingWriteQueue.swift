import Foundation

/// Which field a queued write targets, and the value it should end up as.
enum PendingWriteField: Codable, Equatable {
    case starred(Bool)
    case read(Bool)

    /// Same-kind check for `PendingWriteQueue.enqueue`'s dedup rule -- ignores the carried value,
    /// since a newer pending write for the same field always supersedes an older one.
    fileprivate var isSameKind: (PendingWriteField) -> Bool {
        { other in
            switch (self, other) {
            case (.starred, .starred), (.read, .read): return true
            default: return false
            }
        }
    }
}

/// One article's not-yet-acknowledged star/read change.
struct PendingWrite: Codable, Equatable {
    let articleServerID: Int
    let field: PendingWriteField
}

/// Replaces the old "roll back the local optimistic write on PATCH failure" pattern for both
/// `starred` and `read`. On failure the change is queued here instead of being reverted, and
/// `SyncEngine.sync()` flushes the queue (retrying each entry) before its normal pull -- so a
/// star/read made while offline is retried opportunistically rather than silently lost. Backed by
/// `AppSettings.pendingWrites` (small, transient, device-local state -- not worth a SwiftData
/// model).
@MainActor
enum PendingWriteQueue {
    /// Enqueues `write`, replacing any existing pending entry for the same
    /// `(articleServerID, field kind)` pair -- a newer pending value for the same field always
    /// wins over an older queued one.
    static func enqueue(_ write: PendingWrite, settings: AppSettings) {
        var pending = settings.pendingWrites
        pending.removeAll { $0.articleServerID == write.articleServerID && $0.field.isSameKind(write.field) }
        pending.append(write)
        settings.pendingWrites = pending
    }

    /// Attempts every pending write's PATCH via `actions`. Entries that succeed are removed;
    /// entries that fail (still offline, or a real server error) stay queued for the next flush.
    static func flush(using actions: ArticleActions, settings: AppSettings) async {
        let pending = settings.pendingWrites
        guard !pending.isEmpty else { return }
        var remaining: [PendingWrite] = []
        for write in pending {
            do {
                switch write.field {
                case .starred(let value):
                    try await actions.setStarred(value, articleServerID: write.articleServerID)
                case .read(let value):
                    try await actions.setRead(value, articleServerID: write.articleServerID)
                }
            } catch {
                remaining.append(write)
            }
        }
        settings.pendingWrites = remaining
    }
}
