import Foundation

/// Resolves the timeline's first displayed dataset in a single pass: applies the tag + feed
/// filters and resolves the saved anchor to an index within the filtered list. Building the
/// reader from this result positions it on the anchor immediately — no separate post-build
/// repositioning frame.
enum TimelineBootstrap {
    static func resolve<T: TimelineFilterable & TimelineIdentifiable>(
        summaries: [T],
        disabledTagNames: Set<String>,
        includeUntagged: Bool,
        disabledFeedNames: Set<String>,
        anchorIdentifier: String?
    ) -> (articles: [T], anchorIndex: Int) {
        let byTag = TagFilter.apply(
            to: summaries, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged
        )
        let filtered = FeedFilter.apply(to: byTag, disabledFeedNames: disabledFeedNames)
        let index = TimelineAnchor.index(for: anchorIdentifier, in: filtered)
        return (filtered, index)
    }
}
