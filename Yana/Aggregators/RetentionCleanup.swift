import Foundation
import SwiftData

/// Deletes articles older than the retention window, except those the user has Starred, and
/// returns the canonical UIDs of everything it deleted so the caller can propagate the deletion to
/// iCloud. (Spec §2 — age is the only cleanup criterion; there is no read/unread state.)
enum RetentionCleanup {
    @MainActor
    @discardableResult
    static func run(context: ModelContext, retentionDays: Int, now: Date) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.createdAt < cutoff })
        let candidates = (try? context.fetch(descriptor)) ?? []
        var deletedUIDs: [String] = []
        for article in candidates where !article.isStarred {
            if let uid = ArticleUID.make(for: article) { deletedUIDs.append(uid) }
            context.delete(article)
        }
        return deletedUIDs
    }
}
