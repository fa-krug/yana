import Testing
import Foundation
@testable import Yana

@MainActor
struct SettingsCloudSyncTests {
    final class FakeKV: KeyValueStore {
        var data: [String: Data] = [:]
        func data(forKey key: String) -> Data? { data[key] }
        func set(_ value: Data, forKey key: String) { data[key] = value }
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
}
