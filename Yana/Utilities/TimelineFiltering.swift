import Foundation
import SwiftData

/// Items the timeline filters operate on. Both the full `Article` and the lightweight
/// `ArticleSummary` conform, so the same filter pipeline serves the reader and the list.
protocol TimelineFilterable {
    var filterTagNames: Set<String> { get }
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
        TimelineStableKey.make(identifier: identifier, serverID: serverID)
    }
}

/// The single place a `stableKey` is *encoded*, so a caller holding a loose identifier/serverID
/// pair rather than an item -- `AppSettings.timelineAnchorStableKey`, built from the two persisted
/// anchor fields -- produces exactly the key `TimelineIdentifiable.stableKey` would, and exactly
/// the one `TimelinePageIndex.index(ofStableKey:)` decodes again.
enum TimelineStableKey {
    static func make(identifier: String, serverID: Int?) -> String {
        serverID.map { "s\($0)" } ?? identifier
    }

    /// The same encoding for a pair whose *both* halves can be absent (the persisted anchor
    /// fields). `nil` means there is no anchored article to key off at all.
    static func makeIfPresent(identifier: String?, serverID: Int?) -> String? {
        guard identifier != nil || serverID != nil else { return nil }
        return make(identifier: identifier ?? "", serverID: serverID)
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
    var filterTagNames: Set<String> {
        guard let tagIDs = feed?.tagIDs, !tagIDs.isEmpty else { return [] }
        guard let context = modelContext else { return [] }
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        var namesByID: [Int: String] = [:]
        for tag in tags {
            guard let serverID = tag.serverID else { continue }
            namesByID[serverID] = tag.name
        }
        return Set(tagIDs.compactMap { namesByID[$0] })
    }
    var filterFeedName: String? { feed?.name }
    var filterStarred: Bool { starred }
    var filterRead: Bool { read }
}

extension Article: TimelineIdentifiable {}

extension ArticleSummary: TimelineFilterable {
    var filterTagNames: Set<String> { tagNames }
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
        // Nothing disabled and untagged shown: the filter can't remove anything (audit P6).
        guard !disabledTagNames.isEmpty || !includeUntagged else { return items }
        return items.filter { item in
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

/// Filters the timeline by read state (`AppSettings.readFilter`). A no-op in `.all`.
///
/// `exemptKey` -- the `stableKey` of the article the timeline is currently parked on -- is always
/// kept, whatever its read state. That carve-out is what makes this filter usable at all: an
/// article is marked read the instant it becomes the displayed one, and every recompute runs off
/// `ArticleStore`'s index (which is re-published on that very write), so in `.unread` the article
/// the user just opened would otherwise disappear from the timeline mid-read and take the reader
/// with it. The exemption lapses as soon as the user navigates elsewhere, so a read article drops
/// out once it is genuinely behind them -- which is the point of the filter.
enum ReadFilter {
    static func apply<T: TimelineFilterable & TimelineIdentifiable>(
        to items: [T], mode: ReadFilterMode, exemptKey: String? = nil
    ) -> [T] {
        guard mode != .all else { return items }
        return items.filter { item in
            if let exemptKey, item.stableKey == exemptKey { return true }
            return mode == .unread ? !item.filterRead : item.filterRead
        }
    }
}

/// The timeline's complete filter chain: tags, then feeds, then starred-only, then read state.
/// Every surface that shows the timeline (the iOS reader and its article list, the Mac sidebar,
/// the first-load bootstrap) runs exactly this, so they can never drift apart -- the four of them
/// each used to spell the chain out by hand, and a filter added to one was a filter missing from
/// the others.
///
/// Order within the chain is irrelevant to the result: every pass only ever removes rows, never
/// reorders (see `TimelineOrder`), so the output always keeps `ArticleStore`'s canonical
/// `(createdAt, serverID)` order whatever is filtered out of it.
enum TimelineFilterChain {
    static func apply<T: TimelineFilterable & TimelineIdentifiable>(
        to items: [T],
        disabledTagNames: Set<String>,
        includeUntagged: Bool,
        disabledFeedNames: Set<String>,
        starredOnly: Bool,
        readFilter: ReadFilterMode,
        anchorKey: String?
    ) -> [T] {
        let byTag = TagFilter.apply(
            to: items, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: disabledFeedNames)
        let byStarred = StarredFilter.apply(to: byFeed, starredOnly: starredOnly)
        return ReadFilter.apply(to: byStarred, mode: readFilter, exemptKey: anchorKey)
    }

    /// The same chain, reading every input from `AppSettings` (including the anchored article that
    /// `ReadFilter` exempts). This is what the view/model call sites use.
    @MainActor
    static func apply<T: TimelineFilterable & TimelineIdentifiable>(
        to items: [T], settings: AppSettings
    ) -> [T] {
        apply(
            to: items,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged,
            disabledFeedNames: settings.disabledFeedNames,
            starredOnly: settings.starredOnly,
            readFilter: settings.readFilter,
            anchorKey: settings.timelineAnchorStableKey
        )
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

    /// Resolves a `TimelineIdentifiable.stableKey` value back to an index. This is the counterpart
    /// callers need when the only handle they have back is a `stableKey` itself -- e.g. a SwiftUI
    /// `List`'s `selection` binding, whose `.tag()` values are `stableKey`s, not raw identifiers.
    /// Reverses `stableKey`'s own encoding: an `"s"`-prefixed key is a `serverID`; anything else is
    /// a raw identifier (the unsynced-fixture-data fallback `stableKey` itself falls back to).
    static func index<T: TimelineIdentifiable>(ofStableKey key: String, in items: [T]) -> Int? {
        if key.hasPrefix("s"), let serverID = Int(key.dropFirst()) {
            return items.firstIndex { $0.serverID == serverID }
        }
        return items.firstIndex { $0.identifier == key }
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


