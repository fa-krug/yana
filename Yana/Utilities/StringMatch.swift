import Foundation

/// Shared case/diacritic-insensitive substring matching used by both `ArticleSearch` and
/// `NameSearch`: trim the query, treat an empty/whitespace-only query as "matches everything",
/// otherwise fall back to `localizedStandardContains`.
enum StringMatch {
    /// Trims the query and returns `nil` if it's empty/whitespace-only (i.e. "matches everything").
    static func normalize(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `haystack` contains the (trimmed) query, or `true` if the query is empty.
    static func matches(_ haystack: String, query: String) -> Bool {
        guard let q = normalize(query) else { return true }
        return haystack.localizedStandardContains(q)
    }

    /// Whether any of `haystacks` contains the (trimmed) query, or `true` if the query is empty.
    static func matches(anyOf haystacks: [String], query: String) -> Bool {
        guard let q = normalize(query) else { return true }
        return haystacks.contains { $0.localizedStandardContains(q) }
    }
}
