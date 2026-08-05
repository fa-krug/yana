import Foundation
import SwiftData

@Model
final class Feed {
    var name: String = ""
    /// Server's aggregator key (e.g. "reddit", "heise"), display-only. Nothing client-side
    /// branches on it any more -- there's no native feed creation/editing left to special-case,
    /// since feed management moved to the server's own web UI.
    var aggregator: String = ""
    var identifier: String = ""
    var dailyLimit: Int = 20
    var enabled: Bool = true
    var logoImageHash: String?
    var updatedAt: Date = Date.now

    /// Server-side tag ids this feed currently belongs to (`GET /api/v1/feeds`'s `tagIds`).
    /// A **live** join, refreshed on every `/feeds` fetch -- unlike the old per-article tag
    /// snapshot this replaces, tag membership here always reflects the feed's current state.
    var tagIDs: [Int] = []

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article]?

    init(name: String, aggregator: String, identifier: String, dailyLimit: Int = 20, enabled: Bool = true) {
        self.name = name
        self.aggregator = aggregator
        self.identifier = identifier
        self.dailyLimit = dailyLimit
        self.enabled = enabled
        self.updatedAt = .now
    }
}
