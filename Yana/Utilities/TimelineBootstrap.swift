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
        starredOnly: Bool,
        anchorIdentifier: String?,
        anchorServerID: Int? = nil
    ) -> (articles: [T], anchorIndex: Int) {
        let byTag = TagFilter.apply(
            to: summaries, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: disabledFeedNames)
        let filtered = StarredFilter.apply(to: byFeed, starredOnly: starredOnly)
        let index = TimelineAnchor.index(for: anchorIdentifier, serverID: anchorServerID, in: filtered)
        return (filtered, index)
    }
}
