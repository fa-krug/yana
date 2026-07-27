import Foundation
import Testing
@testable import Yana

@MainActor
struct AppSettingsDiagnosticsTests {

    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "AppSettingsDiagnosticsTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
    }

    @Test func diagnosticsUnlockedDefaultsToFalse() {
        #expect(makeSettings().diagnosticsUnlocked == false)
    }

    @Test func diagnosticsUnlockedPersistsToItsDefaultsStore() {
        let settings = makeSettings()
        settings.diagnosticsUnlocked = true
        #expect(settings.diagnosticsUnlocked)
    }

    @Test func diagnosticsUnlockedIsNeverSyncedToOtherDevices() throws {
        let source = makeSettings()
        source.diagnosticsUnlocked = true

        let destination = makeSettings()
        destination.applySyncedSettings(source.exportSyncedSettings())

        // Device-local by design: the flag must not ride along in the iCloud key-value payload.
        #expect(destination.diagnosticsUnlocked == false)

        let json = try #require(
            try JSONSerialization.jsonObject(with: source.exportSyncedSettings()) as? [String: Any]
        )
        #expect(json["diagnosticsUnlocked"] == nil)
    }
}
