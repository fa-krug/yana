import Foundation

/// Case/diacritic-insensitive substring match over a name, used to search the Feeds and Tags
/// lists. An empty / whitespace-only query matches everything.
enum NameSearch {
    static func matches(_ name: String, query: String) -> Bool {
        StringMatch.matches(name, query: query)
    }

    static func filter<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        guard let q = StringMatch.normalize(query) else { return items }
        return items.filter { matches(name($0), query: q) }
    }
}
