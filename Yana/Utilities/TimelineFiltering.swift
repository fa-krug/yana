import Foundation

/// Filters the timeline by active tags. OR semantics: an article is shown if it has at
/// least one tag that is *not* disabled. Untagged articles are shown only when
/// `includeUntagged` is true.
enum TagFilter {
    static func apply(to articles: [Article], disabledTagNames: Set<String>, includeUntagged: Bool) -> [Article] {
        articles.filter { article in
            let tags = article.tags
            if tags.isEmpty { return includeUntagged }
            // Shown if it has at least one tag that is NOT disabled (OR semantics).
            return tags.contains { !disabledTagNames.contains($0.name) }
        }
    }
}

/// Resolves an article `identifier` to its index in the currently displayed list.
/// Returns `nil` when the identifier is missing — used by the pager's data source to
/// decide whether a neighbouring page exists.
enum TimelinePageIndex {
    static func index(of identifier: String?, in articles: [Article]) -> Int? {
        guard let identifier else { return nil }
        return articles.firstIndex { $0.identifier == identifier }
    }
}

/// Resolves the persisted timeline anchor (an article `identifier`) to an index in the
/// currently displayed list, falling back to 0 (newest) when it is missing.
enum TimelineAnchor {
    static func index(for identifier: String?, in articles: [Article]) -> Int {
        TimelinePageIndex.index(of: identifier, in: articles) ?? 0
    }
}
