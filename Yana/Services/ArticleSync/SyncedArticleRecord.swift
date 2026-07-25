import Foundation
import CryptoKit

/// A single article as it travels through the CloudKit `Articles` zone. `Sendable` value type so it
/// crosses actor boundaries freely. `uid` is the record name; the triple fields let a receiving
/// device link the article to its `Feed`. Bodies are the JSON `[Block]` in `blockData`.
struct SyncedArticleRecord: Sendable, Equatable {
    var uid: String
    var feedIdentifier: String
    var aggregatorType: String
    var articleIdentifier: String
    var title: String
    var url: String
    var author: String
    var summary: String
    var plainText: String
    var leadImageRef: String
    var iconURL: String?
    var date: Date
    var createdAt: Date
    var blockData: Data
    var isStarred: Bool
    var tagNames: [String]
    var imageHashes: [String]
}

/// A content-addressed image blob. `hash` is the record name; `ext` restores the file extension so
/// `ImageStore.fileURL(forHash:)` resolves the right file after a pull.
struct SyncedImageRecord: Sendable, Equatable {
    let hash: String
    let ext: String
    let data: Data
}

/// The delta a pull produces: upserted article records and tombstoned UIDs.
struct ArticleZoneChanges: Sendable, Equatable {
    var articles: [SyncedArticleRecord]
    var deletedUIDs: [String]

    static let empty = ArticleZoneChanges(articles: [], deletedUIDs: [])
}

/// Derives the canonical, cross-device article identity. Uses the stable `(feed, type, identifier)`
/// triple (the same key `StarredMark` uses); when a feed yields no `articleIdentifier`, a
/// deterministic `date+title` hash fills the third segment so the UID is still unique and stable.
///
/// The UID doubles as the `SyncedArticle` CloudKit record name, so it must satisfy CloudKit's
/// limits. Both segments are unbounded source-supplied strings (a feed URL and the source's
/// link/permalink/GUID), and their concatenation can exceed the record-name limit — which makes
/// `CKRecord.ID(recordName:)` raise an ObjC `CKException` that Swift cannot catch, aborting the
/// process. Bounding it here rather than at the CloudKit boundary keeps every consumer in
/// agreement: pushes, tombstones (`ArticleZoneStore.delete(articleUIDs:)`), the synced
/// `timelineAnchorUID`, and local resolution all derive the UID through this one function.
enum ArticleUID {
    /// CloudKit rejects a record name longer than this, measured in UTF-16 code units.
    static let recordNameLimit = 255

    static func make(
        feedIdentifier: String,
        aggregatorType: String,
        articleIdentifier: String,
        date: Date,
        title: String
    ) -> String {
        let third: String
        if articleIdentifier.isEmpty {
            third = hex(of: "\(date.timeIntervalSince1970)|\(title)")
        } else {
            third = articleIdentifier
        }
        let uid = "\(feedIdentifier)|\(aggregatorType)|\(third)"
        guard uid.utf16.count > recordNameLimit else { return uid }
        // Too long for a record name. Collapse the whole thing into a digest instead of truncating:
        // truncation would alias two articles sharing a long prefix onto one record and silently
        // drop one. The digest is deterministic, so every device derives the same name for the same
        // article, and it carries no `|`, so it can never collide with a natural (three-segment)
        // UID. Linking still works on the receiving side because the record keeps the triple in its
        // own fields — `ArticleRecordApply` matches on those, not on the UID.
        return "sha256:\(hex(of: uid))"
    }

    private static func hex(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Collects the `yana-img://<hash>` image hashes referenced anywhere in a block tree (image blocks
/// and embed posters, recursing into blockquotes and list items), deduped.
enum ArticleImageRefs {
    static func hash(from ref: String) -> String? {
        let prefix = "\(ReaderWeb.imageScheme)://"   // "yana-img://"
        guard ref.hasPrefix(prefix) else { return nil }
        let hash = String(ref.dropFirst(prefix.count))
        return hash.isEmpty ? nil : hash
    }

    static func hashes(in blocks: [Block]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ ref: String) {
            guard let h = hash(from: ref), seen.insert(h).inserted else { return }
            ordered.append(h)
        }
        func visit(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case .image(let ref, _): add(ref)
                case .embed(let embed): if let ref = embed.thumbnailRef { add(ref) }
                case .blockquote(let inner): visit(inner)
                case .list(_, let items): items.forEach(visit)
                case .paragraph, .heading, .codeBlock, .divider: break
                }
            }
        }
        visit(blocks)
        return ordered
    }
}
