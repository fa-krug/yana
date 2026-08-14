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

extension TimelineIdentifiable {
    /// A lookup key that's actually unique across the whole library, unlike `identifier` alone --
    /// `identifier` is only a per-feed dedup key (the source article's URL/GUID), so two different
    /// feeds can share one, and a plain identifier match can silently resolve to the wrong feed's
    /// article. Prefers `serverID` (globally unique once synced); falls back to `identifier` only
    /// when there's no `serverID` yet (unsynced debug/screenshot fixture data), where a collision
    /// isn't a real-world concern.
    var stableKey: String {
        serverID.map { "s\($0)" } ?? identifier
    }
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
    /// Prefers an exact `serverID` match when one is supplied -- `identifier` alone is only a
    /// per-feed dedup key (see `TimelineIdentifiable.stableKey`), so two different feeds can share
    /// one and a plain identifier lookup can resolve to the wrong feed's article. Falls back to
    /// `identifier` when no `serverID` is available on the caller's side (e.g. a Mac sidebar click,
    /// which only ever hands back the `List` row's tag value).
    static func index<T: TimelineIdentifiable>(of identifier: String?, serverID: Int? = nil, in items: [T]) -> Int? {
        if let serverID {
            return items.firstIndex { $0.serverID == serverID }
        }
        guard let identifier else { return nil }
        return items.firstIndex { $0.identifier == identifier }
    }
}

/// Resolves the persisted timeline anchor to an index in the displayed list, falling back to the
/// last item (the most recently added article) when missing.
enum TimelineAnchor {
    static func index<T: TimelineIdentifiable>(for identifier: String?, serverID: Int? = nil, in items: [T]) -> Int {
        TimelinePageIndex.index(of: identifier, serverID: serverID, in: items) ?? max(0, items.count - 1)
    }
}

/// The timeline's one and only ordering rule: `createdAt` ascending (the server's own append-only
/// insertion order), then `serverID` as a tiebreak. It is deliberately independent of read state,
/// starred state, and `date`:
///
/// * **Read state must not order anything.** The timeline used to sort read articles ahead of unread
///   ones, so an article changing to read jumped from one block to the other. Since an article is
///   marked read the instant it becomes current, every swipe reordered the list under the user:
///   swiping forward and then back landed on a different article each time, and back-navigating
///   through already-read articles was incoherent. Read state is now display-only.
/// * **`date` must not order anything.** A feed can backfill a publish date out of chronological
///   order, which would retroactively move an article the user had already navigated past.
/// * **`serverID` is required, not cosmetic.** The server stamps `createdAt` with whole-second
///   precision, so one aggregation run gives hundreds of articles the same value; without the
///   tiebreak those ties have no defined order, and the DB's arbitrary choice need not match this
///   comparator's, which is how a single splice could reshuffle a whole batch.
///
/// Every ordering site keys off this: `ArticleSummaryLoader`'s fetch descriptors (which must use the
/// matching `SortDescriptor`s) and `SummaryIndexMerge`'s splice.
enum TimelineOrder {
    static func isOrderedBefore<T: TimelineIdentifiable>(_ a: T, _ b: T) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return (a.serverID ?? 0) < (b.serverID ?? 0)
    }
}


