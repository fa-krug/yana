import CryptoKit
import Foundation

/// Derives the canonical, cross-device article identity. Uses the stable `(feed, type, identifier)`
/// triple (the same key `StarredMark` uses); when a feed yields no `articleIdentifier`, a
/// deterministic `date+title` hash fills the third segment so the UID is still unique and stable.
///
/// Both segments are unbounded source-supplied strings (a feed URL and the
/// source's link/permalink/GUID), and their concatenation can exceed the record-name limit.
/// Bounding it here keeps every consumer in agreement.
enum ArticleUID {
    /// Max size of a UID.
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
        // article, and it carries no `|`, so it can never collide with a natural (three-segment) UID.
        return "sha256:\(hex(of: uid))"
    }

    /// Derive the canonical UID from an article's stored feed identity (falling back to its linked
    /// feed). Returns nil for a legacy article with neither stored identity nor a linked feed.
    ///
    /// `nonisolated`: it only reads plain `@Model` properties (an `Article` is not main-actor
    /// isolated), so callers on any actor can derive the UID.
    nonisolated static func make(for article: Article) -> String? {
        let feedIdentifier = article.syncFeedIdentifier.isEmpty ? article.feed?.identifier : article.syncFeedIdentifier
        let aggregatorType = article.syncAggregatorType.isEmpty ? article.feed?.aggregatorType : article.syncAggregatorType
        guard let feedIdentifier, let aggregatorType else { return nil }
        return make(feedIdentifier: feedIdentifier, aggregatorType: aggregatorType,
                    articleIdentifier: article.identifier, date: article.date, title: article.title)
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
