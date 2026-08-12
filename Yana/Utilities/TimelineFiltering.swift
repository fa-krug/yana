import Foundation
import SwiftData

/// Items the timeline filters operate on. Both the full `Article` and the lightweight
/// `ArticleSummary` conform, so the same filter pipeline serves the reader and the list.
protocol TimelineFilterable {
    var filterTagNames: [String] { get }
    var filterFeedName: String? { get }
    var filterStarred: Bool { get }
    var filterRead: Bool { get }
}

/// Items addressable by their stable `identifier` (the timeline anchor key) and orderable by their
/// `createdAt` insertion order. `date` (the feed's own publish timestamp) is display-only: a feed
/// can backfill it out of chronological order, so it must never drive sort/reinsertion decisions --
/// `createdAt` is assigned once, server-side, at insert and never changes. `serverID` breaks ties,
/// since a bulk import can land more than one row in the same `createdAt` second.
protocol TimelineIdentifiable {
    var identifier: String { get }
    var date: Date { get }
    var createdAt: Date { get }
    var serverID: Int? { get }
}

extension Article: TimelineFilterable {
    /// Tag membership is a live join, not the old per-article snapshot: `Article.tags` is never
    /// populated by `SyncWriter` any more (tag membership lives on `Feed.tagIDs`, refreshed from
    /// `/feeds` each sync). Resolves `feed?.tagIDs` against every synced `Tag` row's `serverID`,
    /// matching `ArticleSummary.tagNameLookup`'s derivation exactly. Production filtering only
    /// ever runs over `[ArticleSummary]` (which precomputes this at construction, once per
    /// index build); this conformance exists for API completeness and direct-`Article` tests, so
    /// a per-call fetch here -- rather than plumbing a lookup map through a parameterless
    /// protocol requirement -- is an acceptable, deliberately un-optimized trade.
    var filterTagNames: [String] {
        guard let tagIDs = feed?.tagIDs, !tagIDs.isEmpty else { return [] }
        guard let context = modelContext else { return [] }
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        var namesByID: [Int: String] = [:]
        for tag in tags {
            guard let serverID = tag.serverID else { continue }
            namesByID[serverID] = tag.name
        }
        return tagIDs.compactMap { namesByID[$0] }
    }
    var filterFeedName: String? { feed?.name }
    var filterStarred: Bool { starred }
    var filterRead: Bool { read }
}

extension Article: TimelineIdentifiable {}

extension ArticleSummary: TimelineFilterable {
    var filterTagNames: [String] { Array(tagNames) }
    var filterFeedName: String? { feedName.isEmpty ? nil : feedName }
    var filterStarred: Bool { isStarred }
    var filterRead: Bool { isRead }
}

extension ArticleSummary: TimelineIdentifiable {}

/// Filters the timeline by active tags. OR semantics: an item is shown if it has at
/// least one tag that is *not* disabled. Untagged items are shown only when
/// `includeUntagged` is true.
enum TagFilter {
    static func apply<T: TimelineFilterable>(
        to items: [T], disabledTagNames: Set<String>, includeUntagged: Bool
    ) -> [T] {
        items.filter { item in
            let names = item.filterTagNames
            if names.isEmpty { return includeUntagged }
            return names.contains { !disabledTagNames.contains($0) }
        }
    }
}

/// Filters the timeline by active feeds. An item is shown unless its source feed is
/// disabled. Items whose feed has been deleted (`filterFeedName == nil`) are always shown.
enum FeedFilter {
    static func apply<T: TimelineFilterable>(to items: [T], disabledFeedNames: Set<String>) -> [T] {
        guard !disabledFeedNames.isEmpty else { return items }
        return items.filter { item in
            guard let name = item.filterFeedName else { return true }
            return !disabledFeedNames.contains(name)
        }
    }
}

/// Filters the timeline to starred items only, when the "Starred Only" quick-filter is on. A
/// no-op (returns `items` unchanged) when `starredOnly` is false.
enum StarredFilter {
    static func apply<T: TimelineFilterable>(to items: [T], starredOnly: Bool) -> [T] {
        guard starredOnly else { return items }
        return items.filter { $0.filterStarred }
    }
}

/// Resolves an item `identifier` to its index in the currently displayed list.
/// Returns `nil` when the identifier is missing.
enum TimelinePageIndex {
    static func index<T: TimelineIdentifiable>(of identifier: String?, in items: [T]) -> Int? {
        guard let identifier else { return nil }
        return items.firstIndex { $0.identifier == identifier }
    }
}

/// Resolves the persisted timeline anchor to an index in the displayed list, falling back
/// to the last item (the newest unread article, or the newest read article if none are unread)
/// when missing.
enum TimelineAnchor {
    static func index<T: TimelineIdentifiable>(for identifier: String?, in items: [T]) -> Int {
        TimelinePageIndex.index(of: identifier, in: items) ?? max(0, items.count - 1)
    }
}

/// Reinserts the currently-displayed article's row at the position it would occupy if it were
/// still unread, whenever it has actually been marked read. `ArticleWrites.markRead` sets the
/// `read` flag the instant an article becomes current (pager swipe, list-open, sidebar selection),
/// which would otherwise immediately move that row from the unread block into the read block --
/// reshuffling the timeline out from under the user mid-navigation. This is a pure, stateless
/// transform recomputed fresh from `articles` every call (never a diff against a remembered
/// previous array), so it can't drift the way a history-dependent merge can: it's correct
/// regardless of what changed underneath it (filter toggles, sync-driven insertions/removals,
/// reopening the list).
///
/// `articles` must already be in canonical `(isRead, createdAt)` order -- the read block first,
/// oldest to newest, then the unread block, oldest to newest -- the same order `TagFilter`/
/// `FeedFilter`/`StarredFilter` preserve from `ArticleStore.summaries` (see `Article.readRank`).
/// Reinsertion is keyed on `TimelineOrder` (`createdAt`, server insertion order), never `date` (the
/// feed's own, possibly-backfilled publish timestamp): once an article is read and unpinned, its
/// `createdAt` never changes again, so its settled position is permanent -- unlike a `date`-keyed
/// reinsertion, which could land a stale, already-read article between the two rows the user just
/// navigated between, corrupting "back" navigation. `identifier` is only a per-feed dedup key (see
/// `SummaryIndexMerge`'s doc comment) so a pin could in principle match the wrong one of two
/// same-identifier rows from different feeds; this is an accepted, pre-existing limitation of using
/// `identifier` as a lookup key throughout this file, not something new here.
enum TimelinePinning {
    static func apply<T: TimelineIdentifiable & TimelineFilterable>(
        to articles: [T], pinning pinnedIdentifier: String?
    ) -> [T] {
        guard let pinnedIdentifier,
              let pinnedIndex = articles.firstIndex(where: { $0.identifier == pinnedIdentifier }),
              articles[pinnedIndex].filterRead
        else { return articles }

        var result = articles
        let pinned = result.remove(at: pinnedIndex)
        let unreadStart = result.firstIndex(where: { !$0.filterRead }) ?? result.count
        let insertionIndex = result[unreadStart...].firstIndex {
            TimelineOrder.isOrderedBefore(pinned, $0)
        } ?? result.count
        result.insert(pinned, at: insertionIndex)
        return result
    }
}

/// The timeline's canonical secondary ordering key: `createdAt` ascending, then `serverID` as a
/// tiebreak for same-second inserts. Shared by `TimelinePinning` and `SummaryIndexMerge` so both
/// always agree on where an article settles once it is no longer pinned -- a single source of
/// truth is what keeps "back" navigation stable across a pin handoff.
enum TimelineOrder {
    static func isOrderedBefore<T: TimelineIdentifiable>(_ a: T, _ b: T) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return (a.serverID ?? 0) < (b.serverID ?? 0)
    }
}


