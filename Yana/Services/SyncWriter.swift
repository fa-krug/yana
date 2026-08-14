import Foundation
import SwiftData

struct SyncArticleSummaryWire: Decodable, Sendable {
    let id: Int
    let feedId: Int
    let name: String
    let identifier: String
    let date: Date
    let author: String
    let read: Bool
    let starred: Bool
    let createdAt: Date
    let updatedAt: Date
}

/// The subset of the server's feed shape this client actually mirrors. The response also carries
/// `aggregator`, `enabled`, `dailyLimit` and `updatedAt`; all four are feed *configuration*, owned
/// and acted on by the server (and edited in its web UI), so nothing here renders them and they are
/// deliberately not decoded. Extra keys in the JSON are ignored by `Decodable`, so dropping them is
/// forwards-compatible.
struct SyncFeedWire: Decodable, Sendable {
    let id: Int
    let name: String
    let identifier: String
    let tagIds: [Int]
    let logoImageHash: String?
}

/// The server's `TagWire` shape (`GET /api/v1/tags`): `{ id, name, color }`.
struct SyncTagWire: Decodable, Sendable {
    let id: Int
    let name: String
    let color: String
}

/// The `SyncEngine`'s write path. Mirrors `AggregationWriter`'s role exactly -- everything it
/// does is a plain `ModelContext` write, so `ArticleStore`'s `ModelContext.didSave` observer
/// picks up every change with no changes needed on that side (see `ArticleStore.swift`).
@ModelActor
actor SyncWriter {
    /// Upserts by `Article.serverID`. Preserves `createdAt` on update (matches the existing
    /// "an article's timeline position never jumps on re-fetch" rule). `read` follows an
    /// upgrade-only rule on update -- the wire can flip local unread->read but never read->unread,
    /// so a stale/racing sync page can't undo a read the user just made (see `Article.setRead`).
    /// Returns the touched rows' `PersistentIdentifier`s so the caller can report progress without a
    /// second fetch.
    @discardableResult
    func upsertSummaries(_ summaries: [SyncArticleSummaryWire]) -> [PersistentIdentifier] {
        var touched: [PersistentIdentifier] = []
        for summary in summaries {
            // Both values are precomputed as plain local `let`s -- matching the pattern
            // `FeedsView.refreshArticleCounts()` already uses (`let id = feed.persistentModelID`
            // before the predicate) -- rather than doing the member access inline inside the
            // closure. Two independent reasons: comparing `Article.serverID` (`Int?`) directly
            // against a captured struct's `.id` member-access expression makes the #Predicate
            // macro treat that member access as its own KeyPath expression, which then fails to
            // unify with the Optional side ("KeyPath<SyncArticleSummaryWire, Int>" vs
            // "...Int?"); and `.description` isn't representable inside `#Predicate` at all (not
            // a `StandardPredicateExpression`) -- same pattern `replaceFeeds` below uses for
            // `idString`.
            let targetServerID = summary.id
            let existingDescriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == targetServerID })
            let feedIdString = summary.feedId.description
            let feedDescriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.identifier == feedIdString })
            // Feeds are looked up by their own serverID equivalent -- see `replaceFeeds` below,
            // which stores the server feed id into `Feed.identifier` verbatim (feeds have no
            // separate natural identifier client-side any more; the server's id *is* the identity).
            let feed = try? modelContext.fetch(feedDescriptor).first

            if let article = try? modelContext.fetch(existingDescriptor).first {
                article.title = summary.name
                article.author = summary.author
                // The wire's `identifier` IS the article's URL/permalink for every aggregator type
                // on the server (confirmed against yana-server's aggregators -- `website`/`reddit`
                // set `identifier` to the scraped/post URL directly, `youtube` to the watch URL).
                // There is no separate `url` field on `ArticleSummaryWire`.
                article.url = summary.identifier
                article.starred = summary.starred
                if summary.read {
                    article.read = true
                }
                article.feed = feed
                // A content update on the server (title/body edit, or just a re-fetch that
                // changed something) must be re-pulled -- reset unconditionally on every update
                // hit so `SyncEngine.backfillMissingContent()`'s `hasContent == false` scan picks
                // it up again. Idempotent and bounded, so doing this even when the update didn't
                // touch the body is harmless: worst case is one redundant `/content` refetch.
                article.hasContent = false
                touched.append(article.persistentModelID)
            } else {
                let article = Article(
                    title: summary.name, identifier: summary.identifier, url: summary.identifier,
                    date: summary.date, author: summary.author
                )
                article.serverID = summary.id
                article.starred = summary.starred
                article.read = summary.read
                article.createdAt = summary.createdAt
                article.feed = feed
                modelContext.insert(article)
                touched.append(article.persistentModelID)
            }
        }
        try? modelContext.save()
        return touched
    }

    /// Decodes `document` into `[Block]` and writes it to the matching article, marking
    /// `hasContent`. Returns `false` (no throw) if no local article with this `serverID` exists
    /// yet -- a race between a summary upsert and its content fetch landing out of order is a
    /// normal, expected condition in a bounded-concurrency pipeline, not an error.
    @discardableResult
    func applyContent(articleServerID: Int, document: WireDocument) -> Bool {
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == articleServerID })
        guard let article = try? modelContext.fetch(descriptor).first else { return false }
        article.blocks = document.blocks
        article.hasContent = true
        try? modelContext.save()
        return true
    }

    /// Deletes one article per given `serverID`, if a local match exists. Looked up one id at a
    /// time (via the same proven `$0.serverID == <plain captured Int>` shape `upsertSummaries`
    /// uses, backed by the `serverID` `#Index`) rather than a single
    /// `serverIDs.contains($0.serverID ?? <sentinel>)` predicate: that shape compiles, but its
    /// `?? `-coalesce lowers to a SQL `TERNARY`, and CoreData's SQL generator cannot use a
    /// `TERNARY` as the left-hand side of an `IN` test -- it throws
    /// `NSInvalidArgumentException: unimplemented SQL generation ... (bad LHS)` at fetch time, a
    /// runtime crash a `try?` around the fetch would silently swallow into "removals did
    /// nothing". Caught by actually running `SyncWriterTests` (see task-9-report.md), not by
    /// reading the code -- it compiles cleanly.
    func applyRemovals(_ serverIDs: [Int]) {
        guard !serverIDs.isEmpty else { return }
        for id in serverIDs {
            let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == id })
            if let article = try? modelContext.fetch(descriptor).first {
                modelContext.delete(article)
            }
        }
        try? modelContext.save()
    }

    /// Full replace-by-upsert of every feed the server returned (the `/feeds` response is small
    /// and unpaginated, so there's no incremental-delta protocol to speak of here -- unlike
    /// articles). Stores the server's feed id as `Feed.identifier` (string form), since feeds
    /// have no other natural identity worth keeping client-side any more.
    @discardableResult
    func replaceFeeds(_ feeds: [SyncFeedWire]) -> [PersistentIdentifier] {
        var seenIdentifiers = Set<String>()
        let touched = upsertAndPrune(
            feeds,
            fetchExisting: { wire in
                let idString = String(wire.id)
                seenIdentifiers.insert(idString)
                let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.identifier == idString })
                return try? modelContext.fetch(descriptor).first
            },
            makeNew: { wire in Feed(name: wire.name, identifier: String(wire.id)) },
            apply: { feed, wire in
                feed.name = wire.name
                feed.tagIDs = wire.tagIds
                feed.logoImageHash = wire.logoImageHash
            }
        )
        // `/feeds` is a full, unpaginated snapshot -- a feed missing from this response was
        // deleted server-side, so its local mirror (and, via the model's cascade delete rule,
        // its articles) must go too. Without this, a deleted feed keeps showing in
        // `TagFilterView`'s Feeds section forever, since this method is otherwise upsert-only.
        pruneMissing(FetchDescriptor<Feed>()) { !seenIdentifiers.contains($0.identifier) }
        try? modelContext.save()
        return touched
    }

    /// Full replace-by-upsert of every tag the server returned, mirroring `replaceFeeds`'s shape
    /// exactly (`/tags` is small and unpaginated too) via the same `upsertAndPrune`/`pruneMissing`
    /// helpers. Populates `Tag.serverID`, which `ArticleSummary.tagNameLookup`/
    /// `Article.filterTagNames` (`TimelineFiltering.swift`) join against `Feed.tagIDs` to resolve
    /// an article's tag names -- tag membership is a live join now, not a per-article snapshot, so
    /// this is the one write path that keeps the `Tag` table itself current. Without it
    /// `TagFilterView`'s Tags section stays permanently empty and every article reads as
    /// "untagged."
    @discardableResult
    func syncTags(_ tags: [SyncTagWire]) -> [PersistentIdentifier] {
        var seenServerIDs = Set<Int>()
        let touched = upsertAndPrune(
            tags,
            fetchExisting: { wire in
                seenServerIDs.insert(wire.id)
                let targetServerID = wire.id
                let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.serverID == targetServerID })
                return try? modelContext.fetch(descriptor).first
            },
            makeNew: { wire in let tag = Tag(name: wire.name, colorHex: wire.color); tag.serverID = wire.id; return tag },
            apply: { tag, wire in
                tag.name = wire.name
                tag.colorHex = wire.color
            }
        )
        // Same full-replace rule `replaceFeeds` follows: drop any local `Tag` the server no
        // longer returns (deleted server-side, or a leftover from before this rework ever wrote
        // a `serverID` at all).
        pruneMissing(FetchDescriptor<Tag>()) { tag in
            guard let serverID = tag.serverID else { return true }
            return !seenServerIDs.contains(serverID)
        }
        try? modelContext.save()
        return touched
    }

    /// Upserts every `wire` element: `fetchExisting` locates (and, as a side effect, records into
    /// the caller's "seen" set) a matching local model, `apply` updates it in place, and `makeNew`
    /// constructs+inserts one when no match exists. Shared by `replaceFeeds`/`syncTags`, which
    /// otherwise independently repeated this exact upsert shape.
    private func upsertAndPrune<Wire, Model: PersistentModel>(
        _ wires: [Wire], fetchExisting: (Wire) -> Model?, makeNew: (Wire) -> Model, apply: (Model, Wire) -> Void
    ) -> [PersistentIdentifier] {
        var touched: [PersistentIdentifier] = []
        for wire in wires {
            let model: Model
            if let existing = fetchExisting(wire) {
                model = existing
            } else {
                model = makeNew(wire)
                modelContext.insert(model)
            }
            // Applied uniformly to both branches -- `makeNew` only needs to satisfy the
            // model's required init parameters; every other field (tags, logo, `updatedAt`, ...)
            // is set here so a new row ends up with exactly the same state an existing one does.
            apply(model, wire)
            touched.append(model.persistentModelID)
        }
        return touched
    }

    /// Deletes every row from `descriptor` for which `shouldPrune` is true. Shared by
    /// `replaceFeeds`/`syncTags`'s "drop what the server's full snapshot no longer lists" pass.
    private func pruneMissing<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>, shouldPrune: (Model) -> Bool) {
        guard let existing = try? modelContext.fetch(descriptor) else { return }
        for model in existing where shouldPrune(model) {
            modelContext.delete(model)
        }
    }

    /// Every `ImageStore` content hash still referenced by a locally-known article's blocks or a
    /// feed's logo -- the "still needed" set `SyncEngine.pruneOrphanedImages` diffs against
    /// `ImageStore.allHashes()`, so an image whose last referencing article (or feed) is gone
    /// (removed via `applyRemovals`, a feed's cascade-delete in `replaceFeeds`, or a local
    /// swipe-to-delete) gets deleted from disk instead of lingering forever.
    func referencedImageHashes() -> Set<String> {
        var hashes = Set<String>()
        if let feeds = try? modelContext.fetch(FetchDescriptor<Feed>()) {
            for feed in feeds {
                if let logo = feed.logoImageHash { hashes.insert(logo) }
            }
        }
        if let articles = try? modelContext.fetch(FetchDescriptor<Article>()) {
            for article in articles {
                hashes.formUnion(Block.imageHashes(in: article.blocks))
            }
        }
        return hashes
    }

    /// The content-backfill candidate list: every locally-known article whose body hasn't
    /// synced yet, oldest-`createdAt`-first, capped at `limit` so one pass never tries to fetch
    /// an unbounded backlog.
    func articlesMissingContent(limit: Int) -> [(persistentID: PersistentIdentifier, serverID: Int)] {
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.hasContent == false && $0.serverID != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = limit
        guard let articles = try? modelContext.fetch(descriptor) else { return [] }
        return articles.compactMap { article in
            guard let serverID = article.serverID else { return nil }
            return (article.persistentModelID, serverID)
        }
    }
}
