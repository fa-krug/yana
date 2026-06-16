import Foundation

/// Case/diacritic-insensitive substring match over a name, used to search the Feeds and Tags
/// lists. An empty / whitespace-only query matches everything.
enum NameSearch {
    static func matches(_ name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return name.localizedStandardContains(q)
    }

    static func filter<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { matches(name($0), query: q) }
    }
}
