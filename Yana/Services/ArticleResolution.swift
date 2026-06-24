import Foundation
import SwiftData

/// Resolves an `ArticleSummary` to its live `Article`. Fast path: the runtime `persistentID`.
/// Fallback: a one-row `identifier` fetch when that id is absent (cache-rehydrated) or stale
/// (after a store migration) — so the reader never lands on a blank page for a known article.
@MainActor
enum ArticleResolution {
    static func resolve(_ summary: ArticleSummary, in context: ModelContext) -> Article? {
        if let pid = summary.persistentID, let article = context.model(for: pid) as? Article {
            return article
        }
        return fetchByIdentifier(summary.identifier, in: context)
    }

    static func fetchByIdentifier(_ identifier: String, in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The most recent article by import date, or nil if the library is empty. Used by the launch
    /// warmer when no saved anchor exists (the reader opens to the newest article in that case).
    static func fetchNewest(in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
