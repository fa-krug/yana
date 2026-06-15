import Foundation
import SwiftData

/// Phase 2 stub. The public API the UI wires to; Phase 4 replaces the bodies with real
/// fetching/parsing/upsert. For now it only flips `isUpdating` and touches `lastFetchedAt`.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Update all enabled feeds.
    func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = (try? context.fetch(descriptor)) ?? []
        for feed in feeds { feed.lastFetchedAt = .now }
        try? context.save()
    }

    /// Update a single feed.
    func update(feed: Feed) async {
        isUpdating = true
        defer { isUpdating = false }
        feed.lastFetchedAt = .now
        try? context.save()
    }

    /// Re-fetch and re-process a single article. No-op in Phase 2.
    func update(article: Article) async {
        isUpdating = true
        defer { isUpdating = false }
    }
}
