import Foundation
import SwiftData

@Model
final class Feed {
    // `SyncWriter` looks feeds up by `identifier` once per upsert batch and per /feeds replace.
    #Index<Feed>([\.identifier])
    var name: String = ""
    var identifier: String = ""
    var logoImageHash: String?

    // Deliberately NOT mirrored from the wire: `aggregator`, `dailyLimit`, `enabled` and
    // `updatedAt`. They were stored on every `/feeds` sync and read by nothing -- feed
    // configuration lives in the server's web UI, and the server only ever sends this client the
    // feeds it wants shown. Re-add a column here only when something actually renders it.

    /// Server-side tag ids this feed currently belongs to (`GET /api/v1/feeds`'s `tagIds`).
    /// A **live** join, refreshed on every `/feeds` fetch -- unlike the old per-article tag
    /// snapshot this replaces, tag membership here always reflects the feed's current state.
    var tagIDs: [Int] = []

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article]?

    init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }
}
