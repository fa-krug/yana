import Foundation

/// One-time cleanup of settings written by older builds. Idempotent and off the launch path.
///
/// Two things need fixing up on an upgrade:
///
/// 1. API keys that an earlier build wrote into the **iCloud-synchronizable** keychain domain are
///    re-saved as device-local, so nothing keeps syncing after that feature was removed.
/// 2. The pre-`UpdateInterval` cadence keys (`backgroundInterval`, and the passive-device flag that
///    meant "don't aggregate here") are mapped onto `AppSettings.updateInterval`, so an upgrading
///    user keeps the refresh schedule they chose instead of silently falling back to the default.
@MainActor
enum LegacySettingsMigration {
    /// Raw `UserDefaults` keys written by builds predating `UpdateInterval`.
    private enum LegacyKey {
        static let passiveDevice = "settings.isPassiveDevice"
        static let backgroundInterval = "settings.backgroundInterval"
    }

    static func runIfNeeded(settings: AppSettings = AppSettings(),
                            defaults: UserDefaults = .standard) {
        guard !settings.hasMigratedKeysToDeviceLocal else { return }

        KeychainService.migrateToDeviceLocal()

        if defaults.bool(forKey: LegacyKey.passiveDevice) {
            settings.updateInterval = .off
        } else if defaults.object(forKey: LegacyKey.backgroundInterval) != nil {
            settings.updateInterval = .nearest(
                toSeconds: defaults.double(forKey: LegacyKey.backgroundInterval)
            )
        }

        settings.hasMigratedKeysToDeviceLocal = true
    }
}
