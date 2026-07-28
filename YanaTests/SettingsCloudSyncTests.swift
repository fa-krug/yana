import Testing
import Foundation
@testable import Yana

@MainActor
struct SettingsCloudSyncTests {
    final class FakeKV: KeyValueStore {
        var data: [String: Data] = [:]
        /// Counts actual writes, distinct from `data.count` (which stays 1 however many times the
        /// same key is overwritten) — needed to assert a burst of anchor changes coalesces into
        /// exactly one push, not just that the final push landed.
        private(set) var setCallCount = 0
        func data(forKey key: String) -> Data? { data[key] }
        func set(_ value: Data, forKey key: String) { data[key] = value; setCallCount += 1 }
        @discardableResult func synchronize() -> Bool { true }
    }

    private func settings(_ suite: String) -> AppSettings {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return AppSettings(defaults: d)
    }

    @Test func pushThenPullRoundTrips() {
        let kv = FakeKV()
        let a = settings("scs-a")
        a.retentionDays = 47
        a.openaiModel = "gpt-4o"
        SettingsCloudSync.push(a, store: kv)
        let b = settings("scs-b")
        SettingsCloudSync.pull(into: b, store: kv)
        #expect(b.retentionDays == 47)
        #expect(b.openaiModel == "gpt-4o")
    }

    @Test func deviceLocalFieldsNotSynced() {
        let kv = FakeKV()
        let a = settings("scs-c")
        a.updateInterval = .off
        SettingsCloudSync.push(a, store: kv)
        let b = settings("scs-d")   // default .min60
        SettingsCloudSync.pull(into: b, store: kv)
        #expect(b.updateInterval == .min60)   // updateInterval is device-local, never in the payload
    }

    @Test func pushSoonEventuallyWritesTheAnchor() async throws {
        let kv = FakeKV()
        let a = settings("scs-e")
        a.timelineAnchorSyncUID = "uid-1"
        let coalescer = AnchorPushCoalescer(interval: .milliseconds(30))

        SettingsCloudSync.pushSoon(a, store: kv, coalescer: coalescer)
        #expect(kv.setCallCount == 0)   // not written synchronously — it's coalesced

        try await Task.sleep(for: .milliseconds(150))
        #expect(kv.setCallCount == 1)
        let decoded = try JSONDecoder().decode(AppSettings.SyncedSettings.self, from: try #require(kv.data(forKey: SettingsCloudSync.key)))
        #expect(decoded.timelineAnchorUID == "uid-1")
    }

    @Test func burstOfAnchorWritesCoalescesIntoOnePush() async throws {
        let kv = FakeKV()
        let a = settings("scs-f")
        let coalescer = AnchorPushCoalescer(interval: .milliseconds(30))

        // A burst of rapid anchor changes (continuous scrolling) within the quiet window.
        for i in 0..<5 {
            a.timelineAnchorSyncUID = "uid-\(i)"
            SettingsCloudSync.pushSoon(a, store: kv, coalescer: coalescer)
        }
        try await Task.sleep(for: .milliseconds(150))

        #expect(kv.setCallCount == 1)   // one write for the whole burst, not five
        let decoded = try JSONDecoder().decode(AppSettings.SyncedSettings.self, from: try #require(kv.data(forKey: SettingsCloudSync.key)))
        #expect(decoded.timelineAnchorUID == "uid-4")   // reflects the LAST position, not an intermediate one
    }
}
