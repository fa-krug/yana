import Foundation
import SwiftData

/// Deletes articles older than the retention window, except those the user has Starred.
/// (Spec §2 — age is the only cleanup criterion; there is no read/unread state.)
enum RetentionCleanup {
    @MainActor
    static func run(context: ModelContext, retentionDays: Int, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.createdAt < cutoff })
        let candidates = (try? context.fetch(descriptor)) ?? []
        for article in candidates where !article.isStarred {
            context.delete(article)
        }
    }
}
