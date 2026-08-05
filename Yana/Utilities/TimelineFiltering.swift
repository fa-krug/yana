import Foundation
import SwiftData

/// Items the timeline filters operate on. Both the full `Article` and the lightweight
/// `ArticleSummary` conform, so the same filter pipeline serves the reader and the list.
protocol TimelineFilterable {
    var filterTagNames: [String] { get }
    var filterFeedName: String? { get }
    var filterStarred: Bool { get }
}

/// Items addressable by their stable `identifier` (the timeline anchor key).
protocol TimelineIdentifiable {
    var identifier: String { get }
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
}

extension Article: TimelineIdentifiable {}

extension ArticleSummary: TimelineFilterable {
    var filterTagNames: [String] { Array(tagNames) }
    var filterFeedName: String? { feedName.isEmpty ? nil : feedName }
    var filterStarred: Bool { isStarred }
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
/// to the newest item (last index in the ascending timeline) when missing.
enum TimelineAnchor {
    static func index<T: TimelineIdentifiable>(for identifier: String?, in items: [T]) -> Int {
        TimelinePageIndex.index(of: identifier, in: items) ?? max(0, items.count - 1)
    }
}


