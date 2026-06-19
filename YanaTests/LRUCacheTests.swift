import Testing
@testable import Yana

@MainActor
struct LRUCacheTests {
    @Test func insertAndRetrieve() {
        let c = LRUCache<String, Int>(capacity: 2)
        c.insert(1, for: "a")
        #expect(c.value(for: "a") == 1)
        #expect(c.value(for: "missing") == nil)
    }

    @Test func evictsLeastRecentlyUsedOverCapacity() {
        let c = LRUCache<String, Int>(capacity: 2)
        c.insert(1, for: "a")
        c.insert(2, for: "b")
        let evicted = c.insert(3, for: "c")  // capacity 2 → "a" evicted
        #expect(evicted == 1)
        #expect(c.value(for: "a") == nil)
        #expect(c.value(for: "b") == 2)
        #expect(c.value(for: "c") == 3)
    }

    @Test func accessPromotesToMostRecentlyUsed() {
        let c = LRUCache<String, Int>(capacity: 2)
        c.insert(1, for: "a")
        c.insert(2, for: "b")
        _ = c.value(for: "a")               // "a" now MRU, "b" is LRU
        c.insert(3, for: "c")               // evicts "b"
        #expect(c.value(for: "b") == nil)
        #expect(c.value(for: "a") == 1)
    }

    @Test func trimEvictsEverythingNotKept() {
        let c = LRUCache<String, Int>(capacity: 5)
        c.insert(1, for: "a"); c.insert(2, for: "b"); c.insert(3, for: "c")
        let evicted = c.trim(toKeep: ["b"]).sorted()
        #expect(evicted == [1, 3])
        #expect(c.value(for: "b") == 2)
        #expect(c.count == 1)
    }
}
