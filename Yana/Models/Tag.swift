import Foundation
import SwiftData

@Model
final class Tag {
    #Index<Tag>([\.serverID])
    var name: String = ""
    var colorHex: String?

    /// This tag's id on the paired server -- the identity `SyncWriter.syncTags` upserts/removes
    /// by, and what `Feed.tagIDs` references for the live tag-membership join (see
    /// `ArticleSummary.tagNameLookup`/`Article.filterTagNames` in `TimelineFiltering.swift`).
    /// Mirrors `Article.serverID`'s rationale exactly: optional rather than defaulted to `0` so a
    /// bug that forgets to set it is a visible `nil`, not a silently-wrong `0` matching a real
    /// server id. `nil` only for a tag that predates this rework's first `/tags` sync.
    var serverID: Int?

    // No `articles` relationship: tag membership is a live join through `Feed.tagIDs`, never a
    // per-article snapshot. See the note on `Article.feed`.

    init(name: String, colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
    }
}
