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
    /// The owning feed's stable identifier, used (with `aggregatorType`) to derive the collision-free
    /// cross-device `uid`. Falls back to the article's own sync snapshot when the feed relationship
    /// has been severed (deleted feed).
    let feedIdentifier: String
    /// The owning feed's `AggregatorType.rawValue`, used (with `feedIdentifier`) to derive `uid`.
    let aggregatorType: String

    var id: String { identifier }

    /// The canonical cross-device article UID (matches `ArticleUID.make`), used to resolve a synced
    /// timeline anchor exactly, without the cross-feed collisions a bare `identifier` allows.
    var uid: String {
        ArticleUID.make(feedIdentifier: feedIdentifier, aggregatorType: aggregatorType,
                         articleIdentifier: identifier, date: date, title: title)
    }

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
        feedIdentifier = article.feed?.identifier ?? article.syncFeedIdentifier
        aggregatorType = article.feed?.aggregatorType ?? article.syncAggregatorType
    }

    // Persist every field EXCEPT the runtime-only `persistentID`.
    private enum CodingKeys: String, CodingKey {
        case identifier, title, feedName, feedLogoHash, author, date, createdAt, tagNames, isStarred
        case feedIdentifier, aggregatorType
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
        // Older disk-cached summaries predate these fields; default to "" so they still decode.
        feedIdentifier = try c.decodeIfPresent(String.self, forKey: .feedIdentifier) ?? ""
        aggregatorType = try c.decodeIfPresent(String.self, forKey: .aggregatorType) ?? ""
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
        try c.encode(feedIdentifier, forKey: .feedIdentifier)
        try c.encode(aggregatorType, forKey: .aggregatorType)
    }
}
