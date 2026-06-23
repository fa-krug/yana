import Foundation
import SwiftData

/// Lightweight, `Sendable` snapshot of an `Article`'s timeline/list metadata — no HTML.
/// Both the reader pager and the article list browse these; the full `Article` (with
/// `content`) is resolved per page by `persistentID` only when a page renders.
struct ArticleSummary: Identifiable, Sendable, Hashable, Codable {
    /// Runtime-only fast-resolve hint. NOT persisted: `PersistentIdentifier` traps when
    /// round-tripped through an external coder and is invalid across launches anyway. `nil` when
    /// the summary was rehydrated from the disk cache; `ArticleResolution` then resolves by
    /// `identifier`.
    let persistentID: PersistentIdentifier?
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

    // Persist every field EXCEPT the runtime-only `persistentID`.
    private enum CodingKeys: String, CodingKey {
        case identifier, title, feedName, feedLogoHash, author, date, createdAt, tagNames, isStarred
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persistentID = nil
        identifier = try c.decode(String.self, forKey: .identifier)
        title = try c.decode(String.self, forKey: .title)
        feedName = try c.decode(String.self, forKey: .feedName)
        feedLogoHash = try c.decodeIfPresent(String.self, forKey: .feedLogoHash)
        author = try c.decode(String.self, forKey: .author)
        date = try c.decode(Date.self, forKey: .date)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        tagNames = try c.decode(Set<String>.self, forKey: .tagNames)
        isStarred = try c.decode(Bool.self, forKey: .isStarred)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(title, forKey: .title)
        try c.encode(feedName, forKey: .feedName)
        try c.encodeIfPresent(feedLogoHash, forKey: .feedLogoHash)
        try c.encode(author, forKey: .author)
        try c.encode(date, forKey: .date)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(tagNames, forKey: .tagNames)
        try c.encode(isStarred, forKey: .isStarred)
    }
}
