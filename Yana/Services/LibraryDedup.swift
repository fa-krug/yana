import Foundation
import SwiftData

/// Collapses duplicate rows that CloudKit can create (two devices producing the "same" logical
/// object, or two pre-migration libraries merging on first sync). CloudKit forbids unique
/// constraints, so uniqueness is enforced here, by natural key, after merges.
@ModelActor
actor LibraryDeduper {
    /// Returns the number of rows deleted.
    func deduplicate() throws -> Int {
        var deleted = 0
        deleted += try dedupeFeeds()
        deleted += try dedupeTags()
        deleted += try dedupeArticles()
        if deleted > 0 { try modelContext.save() }
        return deleted
    }

    private func dedupeFeeds() throws -> Int {
        let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
        var groups: [String: [Feed]] = [:]
        for feed in feeds { groups["\(feed.aggregatorType)|\(feed.identifier)", default: []].append(feed) }
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                // Re-point loser's articles to the survivor BEFORE deleting, to prevent
                // cascade deletion from removing articles that belong to the surviving feed.
                for article in loser.articles ?? [] { article.feed = survivor }
                for tag in loser.tags ?? [] where !(survivor.tags ?? []).contains(where: { $0.id == tag.id }) {
                    var t = survivor.tags ?? []
                    t.append(tag)
                    survivor.tags = t
                }
                modelContext.delete(loser)
                deleted += 1
            }
        }
        return deleted
    }

    private func dedupeTags() throws -> Int {
        let tags = try modelContext.fetch(FetchDescriptor<Tag>())
        var groups: [String: [Tag]] = [:]
        for tag in tags { groups[tag.name, default: []].append(tag) }
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                for article in loser.articles ?? [] where !(article.tags ?? []).contains(where: { $0.id == survivor.id }) {
                    var t = article.tags ?? []
                    t.append(survivor)
                    article.tags = t
                }
                for feed in loser.feeds ?? [] where !(feed.tags ?? []).contains(where: { $0.id == survivor.id }) {
                    var t = feed.tags ?? []
                    t.append(survivor)
                    feed.tags = t
                }
                modelContext.delete(loser)
                deleted += 1
            }
        }
        return deleted
    }

    private func dedupeArticles() throws -> Int {
        let articles = try modelContext.fetch(FetchDescriptor<Article>())
        var groups: [String: [Article]] = [:]
        for article in articles {
            guard let uid = ArticleUID.make(for: article) else { continue }
            groups[uid, default: []].append(article)
        }
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }   // earliest = first-writer-wins
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                if loser.isStarred {
                    for tag in (loser.tags ?? []) where tag.isBuiltIn
                        && !(survivor.tags ?? []).contains(where: { $0.id == tag.id }) {
                        var t = survivor.tags ?? []
                        t.append(tag)
                        survivor.tags = t
                    }
                }
                modelContext.delete(loser)
                deleted += 1
            }
        }
        return deleted
    }
}

/// Fire-and-forget dedup pass, off the render path.
enum LibraryDedup {
    static func run(container: ModelContainer) {
        Task.detached(priority: .utility) {
            _ = try? await LibraryDeduper(modelContainer: container).deduplicate()
        }
    }
}
