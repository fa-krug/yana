import Foundation
import SwiftData

@Model
final class Article {
    // Cold-path fetches sort/filter by these: createdAt drives the anchor window, full index
    // load, fetchNewest, and SyncWriter's oldest-first content-backfill order; date sorts the
    // search results; identifier drives the one-row fetchByIdentifier lookup (a per-feed dedup key,
    // not globally unique); serverID drives SyncWriter's upsert/removal/content-backfill lookups,
    // ArticleResolution's fetchByServerID, and every timeline anchor/pager lookup that prefers
    // it over identifier (see TimelineIdentifiable.stableKey) -- it's globally unique once synced,
    // so it also breaks createdAt ties in the timeline sort. Without an index each is a full table
    // scan over the retained library.
    // Single-column (no query filters on both together). Additive metadata — SwiftData handles it
    // via lightweight migration.
    // Only one #Index macro is allowed per @Model, so every indexed keypath group lives here.
    #Index<Article>([\.date], [\.createdAt], [\.identifier], [\.serverID])
    var title: String = ""
    /// URL or external id; dedup key within a feed.
    var identifier: String = ""
    var url: String = ""
    /// JSON-encoded `[Block]` — the native reader body. Empty until synced.
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
    /// it deliberately takes no part in the timeline's order (see `TimelineOrder`).
    ///
    /// There used to be a parallel `readRank: Int` mirror of this flag, because read state was once
    /// the timeline's primary sort key and `Bool` is not `Comparable`. `TimelineOrder` dropped read
    /// state from the sort entirely; the mirror column (and its index, which every sync insert paid
    /// to maintain) was then carried for a while purely to leave the stored schema untouched, and is
    /// now gone. A new sort must not reintroduce it — see `TimelineOrder`'s doc comment for why
    /// ordering on read state reshuffles the list under the user's finger.
    var read: Bool = false
    /// Whether this article's content has been synced yet (`false` right after its summary
    /// arrives from `/articles/sync`, `true` once `/articles/:id/content` succeeds). Drives the
    /// sync engine's content-backfill retry, not just a display flag.
    var hasContent: Bool = false

    // NOTE: no per-article tag relationship. Tag membership is a live join from the owning feed's
    // current `Feed.tagIDs` against the synced `Tag` table -- see `ArticleSummary.tagNameLookup`
    // and `Article.filterTagNames`. The old `tags: [Tag]?` snapshot column was never populated by
    // `SyncWriter`, yet every light timeline fetch prefetched it as a relationship; it is gone.

    var feed: Feed?

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
        summary: String = ""
    ) {
        self.title = title
        self.identifier = identifier
        self.url = url
        self.date = date
        self.author = author
        self.summary = summary
        self.createdAt = .now
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
