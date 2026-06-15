import Foundation

/// Filters the timeline by active tags. OR semantics: an article is shown if it has at
/// least one tag that is *not* disabled. Untagged articles are shown only when
/// `includeUntagged` is true.
enum TagFilter {
    static func apply(to articles: [Article], disabledTagNames: Set<String>, includeUntagged: Bool) -> [Article] {
        articles.filter { article in
            let names = Set(article.tags.map(\.name))
            if names.isEmpty { return includeUntagged }
            return !names.isSubset(of: disabledTagNames)
        }
    }
}

/// Resolves the persisted timeline anchor (an article `identifier`) to an index in the
/// currently displayed list, falling back to 0 (newest) when it is missing.
enum TimelineAnchor {
    static func index(for identifier: String?, in articles: [Article]) -> Int {
        guard let identifier,
              let idx = articles.firstIndex(where: { $0.identifier == identifier }) else { return 0 }
        return idx
    }
}
