import Foundation

/// A simple bounded least-recently-used cache. `order` holds keys from LRU (first) to MRU (last);
/// `store` holds the values. Used by the reader to keep recently-seen page controllers warm while
/// capping how many live `WKWebView`s exist at once.
@MainActor
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var store: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { store.count }
    var keys: [Key] { order }

    /// Returns the value and promotes the key to most-recently-used.
    func value(for key: Key) -> Value? {
        guard let value = store[key] else { return nil }
        promote(key)
        return value
    }

    /// Inserts/updates a value as most-recently-used. Returns an evicted value if capacity was hit.
    @discardableResult
    func insert(_ value: Value, for key: Key) -> Value? {
        store[key] = value
        promote(key)
        guard store.count > capacity, let lru = order.first else { return nil }
        order.removeFirst()
        return store.removeValue(forKey: lru)
    }

    @discardableResult
    func removeValue(for key: Key) -> Value? {
        order.removeAll { $0 == key }
        return store.removeValue(forKey: key)
    }

    /// Evicts every entry whose key is not in `keys`. Returns the evicted values.
    func trim(toKeep keys: Set<Key>) -> [Value] {
        let drop = order.filter { !keys.contains($0) }
        order.removeAll { !keys.contains($0) }
        return drop.compactMap { store.removeValue(forKey: $0) }
    }

    private func promote(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
