import Foundation
import SwiftData

@Model
final class Article {
    // Cold-path fetches sort/filter by these: createdAt drives the anchor window, full index
    // load, and fetchNewest; identifier drives the one-row fetchByIdentifier lookup. Without an
    // index each is a full table scan over the retained library. Single-column (no query filters
    // on both together). Additive metadata — SwiftData handles it via lightweight migration.
    #Index<Article>([\.createdAt], [\.identifier])
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
    var date: Date = Date.now
    var author: String = ""
    var iconURL: String?
    /// AI-generated summary, shown above the body in the reader. Defaulted for lightweight
    /// SwiftData migration; empty when summarization is off.
    var summary: String = ""
    var createdAt: Date = Date.now

    /// Snapshot of the feed's tags at import, plus the built-in Starred tag when starred.
    var tags: [Tag] = []

    var feed: Feed?

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

    /// Starred state is expressed purely as membership of the built-in tag.
    var isStarred: Bool { tags.contains { $0.isBuiltIn } }

    /// Add or remove the built-in Starred tag.
    func setStarred(_ starred: Bool, using starredTag: Tag) {
        if starred {
            if !tags.contains(where: { $0.id == starredTag.id }) { tags.append(starredTag) }
        } else {
            tags.removeAll { $0.isBuiltIn }
        }
    }
}
