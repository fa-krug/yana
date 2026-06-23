import Foundation
import SwiftData

/// Lightweight, `Sendable` snapshot of an `Article`'s timeline/list metadata — no HTML.
/// Both the reader pager and the article list browse these; the full `Article` (with
/// `content`) is resolved per page by `persistentID` only when a page renders.
struct ArticleSummary: Identifiable, Sendable, Hashable {
    let persistentID: PersistentIdentifier
    let identifier: String
    let title: String
    let feedName: String
    let feedLogoHash: String?
    let author: String
    let date: Date
    let createdAt: Date
    let tagNames: Set<String>
    let isStarred: Bool

    var id: String { identifier }

    init(_ article: Article) {
        persistentID = article.persistentModelID
        identifier = article.identifier
        title = article.title
        feedName = article.feed?.name ?? ""
        feedLogoHash = article.feed?.logoHash
        author = article.author
        date = article.date
        createdAt = article.createdAt
        tagNames = Set(article.tags.map(\.name))
        isStarred = article.isStarred
    }
}
