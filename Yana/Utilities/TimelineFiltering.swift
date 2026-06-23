import Foundation

/// Items the timeline filters operate on. Both the full `Article` and the lightweight
/// `ArticleSummary` conform, so the same filter pipeline serves the reader and the list.
protocol TimelineFilterable {
    var filterTagNames: [String] { get }
    var filterFeedName: String? { get }
}

/// Items addressable by their stable `identifier` (the timeline anchor key).
protocol TimelineIdentifiable {
    var identifier: String { get }
}

extension Article: TimelineFilterable {
    var filterTagNames: [String] { tags.map(\.name) }
    var filterFeedName: String? { feed?.name }
}

extension Article: TimelineIdentifiable {}

extension ArticleSummary: TimelineFilterable {
    var filterTagNames: [String] { Array(tagNames) }
    var filterFeedName: String? { feedName.isEmpty ? nil : feedName }
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
