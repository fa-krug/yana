import CryptoKit
import Foundation

/// Derives the canonical article identity used by the timeline anchor, retention, and dedup. Uses
/// the stable `(feed, type, identifier)` triple (the same key `StarredMark` uses); when a feed
/// yields no `articleIdentifier`, a deterministic `date+title` hash fills the third segment so the
/// UID is still unique and stable.
///
/// Both segments are unbounded source-supplied strings (a feed URL and the source's
/// link/permalink/GUID), so the UID is length-bounded here rather than at each consumer.
enum ArticleUID {
    /// Longest UID emitted verbatim, measured in UTF-16 code units. Anything longer collapses to a
    /// digest so a UID is never unbounded.
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
        // Too long. Collapse the whole thing into a digest instead of truncating: truncation would
        // alias two articles sharing a long prefix onto one UID and silently drop one. The digest is
        // deterministic, and it carries no `|`, so it can never collide with a natural
        // (three-segment) UID.
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
