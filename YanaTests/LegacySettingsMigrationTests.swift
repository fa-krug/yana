import Foundation
import Testing
@testable import Yana

/// The upgrade path off the removed iCloud-sync build: keys come back to this device, and the
/// pre-`UpdateInterval` cadence keys keep their meaning instead of silently resetting.
@MainActor
@Suite("LegacySettingsMigration")
struct LegacySettingsMigrationTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "LegacySettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func passiveDeviceFlagMapsToOff() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "settings.isPassiveDevice")
        let settings = AppSettings(defaults: defaults)

        LegacySettingsMigration.runIfNeeded(settings: settings, defaults: defaults)

        #expect(settings.updateInterval == .off)
        #expect(settings.hasMigratedKeysToDeviceLocal)
    }

    @Test func legacyBackgroundIntervalMapsToTheNearestCase() {
        let defaults = freshDefaults()
        defaults.set(3600.0, forKey: "settings.backgroundInterval")
        let settings = AppSettings(defaults: defaults)

        LegacySettingsMigration.runIfNeeded(settings: settings, defaults: defaults)

        #expect(settings.updateInterval == .min60)
    }

    @Test func noLegacyKeysLeavesTheIntervalAlone() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.updateInterval = .hour4

        LegacySettingsMigration.runIfNeeded(settings: settings, defaults: defaults)

        #expect(settings.updateInterval == .hour4)
    }

    /// Idempotent: a second run must not re-apply a legacy key over a choice the user has since
    /// changed in Settings.
    @Test func doesNotRunTwice() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "settings.isPassiveDevice")
        let settings = AppSettings(defaults: defaults)

        LegacySettingsMigration.runIfNeeded(settings: settings, defaults: defaults)
        settings.updateInterval = .hour2
        LegacySettingsMigration.runIfNeeded(settings: settings, defaults: defaults)

        #expect(settings.updateInterval == .hour2)
    }
}
