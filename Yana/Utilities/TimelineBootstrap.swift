import Foundation

/// Resolves the timeline's first displayed dataset in a single pass: applies the whole filter chain
/// (`TimelineFilterChain`) and resolves the saved anchor to an index within the filtered list.
/// Building the reader from this result positions it on the anchor immediately — no separate
/// post-build repositioning frame.
enum TimelineBootstrap {
    static func resolve<T: TimelineFilterable & TimelineIdentifiable>(
        summaries: [T],
        disabledTagNames: Set<String>,
        includeUntagged: Bool,
        disabledFeedNames: Set<String>,
        starredOnly: Bool,
        readFilter: ReadFilterMode,
        anchorIdentifier: String?,
        anchorServerID: Int? = nil
    ) -> (articles: [T], anchorIndex: Int) {
        // The anchor doubles as the read filter's exemption (see `ReadFilter.apply`): the article
        // being resumed must survive the filter, or the reader would open somewhere else entirely.
        let filtered = TimelineFilterChain.apply(
            to: summaries,
            disabledTagNames: disabledTagNames,
            includeUntagged: includeUntagged,
            disabledFeedNames: disabledFeedNames,
            starredOnly: starredOnly,
            readFilter: readFilter,
            anchorKey: TimelineStableKey.makeIfPresent(identifier: anchorIdentifier, serverID: anchorServerID)
        )
        let index = TimelineAnchor.index(for: anchorIdentifier, serverID: anchorServerID, in: filtered)
        return (filtered, index)
    }
}
