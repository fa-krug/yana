import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Passive device")
struct PassiveDeviceTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "Passive.\(UUID().uuidString)")! }

    @Test("isPassiveDevice defaults to false and persists")
    func persists() {
        let d = suite()
        let s = AppSettings(defaults: d)
        #expect(s.isPassiveDevice == false)
        s.isPassiveDevice = true
        #expect(AppSettings(defaults: d).isPassiveDevice == true)
    }

    @Test("isPassiveDevice is absent from the synced settings payload")
    func notSynced() {
        let d = suite()
        let s = AppSettings(defaults: d)
        s.isPassiveDevice = true
        let data = s.exportSyncedSettings()
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("isPassiveDevice"))
        #expect(!json.contains("PassiveDevice"))
    }
}
