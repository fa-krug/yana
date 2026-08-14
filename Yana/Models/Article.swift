import Foundation
import SwiftData

@Model
final class Article {
    // Cold-path fetches sort/filter by these: createdAt drives the anchor window, full index
    // load, fetchNewest, and SyncWriter's oldest-first content-backfill order; date is fetched for
    // display only; identifier drives the one-row fetchByIdentifier lookup (a per-feed dedup key,
    // not globally unique); serverID drives SyncWriter's upsert/removal/content-backfill lookups,
    // ArticleResolution's fetchByServerID, and every timeline anchor/pager lookup that prefers
    // it over identifier (see TimelineIdentifiable.stableKey) -- it's globally unique once synced,
    // so it also breaks createdAt ties in the timeline sort. readRank is indexed only for
    // historical reasons (it no longer sorts anything -- see its doc comment); dropping the index
    // would be a schema change for no gain. Without an index each is a full table scan over the
    // retained library.
    // Single-column (no query filters on both together). Additive metadata — SwiftData handles it
    // via lightweight migration.
    // Only one #Index macro is allowed per @Model, so every indexed keypath group lives here.
    #Index<Article>([\.date], [\.createdAt], [\.identifier], [\.serverID], [\.readRank])
    var title: String = ""
    /// URL or external id; dedup key within a feed.
    var identifier: String = ""
    var url: String = ""
    /// Legacy pre-migration HTML body. Retained ONLY so the one-time `BlockMigration` sweep can
    /// convert existing articles into `blockData`; the sweep clears it once converted, and newly
    /// imported articles never populate it (they store blocks directly). Not rendered. Kept as a
    /// stored `String` so the SwiftData migration is lightweight (no in-place type change) and the
    /// existing HTML survives the upgrade for conversion.
    var content: String = ""
    /// JSON-encoded `[Block]` — the native reader body. Empty until imported/converted.
    var blockData: Data = Data()
    /// The body flattened to visible text: the search surface (`ArticleSearch`/`ArticleListSearch`)
    /// and the read-aloud surface. Derived once at import / conversion from the blocks.
    var plainText: String = ""
    /// Denormalized ref of the lead image (the first block when it is an image), else empty. Kept in
    /// sync by the `blocks` setter so the reader can warm the header image ahead of a swipe WITHOUT
    /// decoding the whole `[Block]` body just to peek at its first element — that peek ran several
    /// times per swipe (prewarm × neighbors + transition), each a full JSON decode. Empty for
    /// articles imported before this column existed; they simply skip the warm-up (harmless) and age
    /// out under retention. Defaulted for lightweight SwiftData migration.
    var leadImageRef: String = ""
    /// The original article date reported by the source (the server's `date`, from the feed/site
    /// itself) -- shown in the reader/timeline, but display-only: a feed can backfill this out of
    /// chronological order, so the timeline sorts by `createdAt` instead, never this. Not
    /// re-stamped on a sync update (see `SyncWriter.upsertSummaries`), matching the server's own
    /// treatment of a publication date as immutable.
    var date: Date = Date.now
    var author: String = ""
    var iconURL: String?
    /// AI-generated summary, shown above the body in the reader. Defaulted for lightweight
    /// SwiftData migration; empty when summarization is off.
    var summary: String = ""
    /// When this article was first synced to this device -- mirrors the server's own `createdAt`
    /// (its stable, append-only, backfill-proof insertion order key; see `SyncWriter`'s wire
    /// decode). Not shown in the UI, but it IS the timeline's sort order, together with `serverID` as
    /// a tiebreak (`ArticleStore`, `SummaryIndexMerge`, `TimelineOrder`), and it also drives
    /// `SyncWriter`'s oldest-first content-backfill order. Preserved across updates, so neither a
    /// re-fetch nor a backfilled `date` can ever reorder an article once synced -- this is what makes
    /// "back" navigation land on a stable, identical-across-devices article every time.
    var createdAt: Date = Date.now

    var starred: Bool = false
    /// Whether the server (or a local mark-as-read) considers this article read. Display state only:
    /// it deliberately takes no part in the timeline's order (see `TimelineOrder`). Never assign
    /// this directly; always go through `setRead(_:)` so `readRank` stays in sync (SwiftData's
    /// `@Model` macro fully owns this property's accessors, so a `didSet` here is not an option —
    /// same reason `blocks` below is a separate plain computed property rather than an observer on
    /// `blockData`).
    var read: Bool = false
    /// Mirrors `read` as a `SortDescriptor`-sortable key (`0` read, `1` unread), since `Bool` is not
    /// `Comparable`. **No longer part of any timeline sort** — read state used to be the timeline's
    /// primary sort key, which reordered the list under the user on every swipe (see `TimelineOrder`
    /// for the full reasoning). Retained, still kept in sync by `setRead(_:)`, purely so the stored
    /// schema is unchanged for existing installs; a new sort must never use it.
    var readRank: Int = 1
    /// Whether this article's content has been synced yet (`false` right after its summary
    /// arrives from `/articles/sync`, `true` once `/articles/:id/content` succeeds). Drives the
    /// sync engine's content-backfill retry, not just a display flag.
    var hasContent: Bool = false

    /// Snapshot of the feed's tags at import.
    var tags: [Tag]?

    var feed: Feed?

    /// The owning feed's identity, denormalized so a synced article that arrives before its feed
    /// (or whose feed was deleted) can still be identified, deduped by UID, and re-linked when the
    /// feed appears. Set at import (from the feed) and on sync apply (from the record). Empty only
    /// for articles imported before this column existed. Defaulted for lightweight SwiftData migration.
    var syncFeedIdentifier: String = ""
    var syncAggregatorType: String = ""

    /// This article's id on the paired server -- the identity `SyncWriter` upserts/removes by.
    /// `nil` only ever transiently (never persisted that way in practice, since every article now
    /// originates from a sync response) -- kept optional rather than defaulted to `0` so a bug that
    /// forgets to set it is a visible `nil`, not a silently-wrong `0` matching a real server id.
    var serverID: Int?

    init(
        title: String,
        identifier: String,
        url: String,
        date: Date = .now,
        author: String = "",
        iconURL: String? = nil,
        summary: String = ""
    ) {
        self.title = title
        self.identifier = identifier
        self.url = url
        self.date = date
        self.author = author
        self.iconURL = iconURL
        self.summary = summary
        self.createdAt = .now
    }

    /// The only supported way to change `read` — keeps `readRank` in sync. See `readRank`'s doc
    /// comment for why a property observer isn't used instead.
    func setRead(_ value: Bool) {
        read = value
        readRank = value ? 0 : 1
    }

    /// The decoded native body blocks. Decoding is cheap (JSON), so the reader resolves these on
    /// demand per page; the setter keeps `blockData` and `plainText` in sync.
    var blocks: [Block] {
        get { (try? JSONDecoder().decode([Block].self, from: blockData)) ?? [] }
        set {
            blockData = (try? JSONEncoder().encode(newValue)) ?? Data()
            plainText = BlockParser.plainText(newValue)
            if case let .image(ref, _)? = newValue.first { leadImageRef = ref } else { leadImageRef = "" }
        }
    }
}
