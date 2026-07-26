import Foundation
import SwiftData

/// One-time migration from the hand-built CloudKit stack to native SwiftData+CloudKit mirroring.
/// Idempotent and off the launch path. Steps: seed StoredImage rows from the on-disk cache, force
/// API keys synchronizable, map the old backgroundInterval/passive flag to UpdateInterval, and mirror
/// current synced prefs into the iCloud key-value store. Old CloudKit zones are removed separately
/// (LegacyCloudKitCleanup), on its own retry flag.
@MainActor
enum NativeCloudKitMigration {
    static func runIfNeeded(
        container: ModelContainer,
        settings: AppSettings = AppSettings(),
        imageStore: ImageStore = .shared
    ) async {
        guard !settings.hasMigratedToNativeCloudKit else { return }

        // 1. Seed StoredImage from every blob already cached on disk.
        let hashes = await imageStore.allHashes()
        await ImageSync.ensureStored(hashes: hashes, context: container.mainContext, imageStore: imageStore)

        // 2. Re-save all existing API keys unconditionally so any key stored by the old
        //    non-sync build is migrated into the current (synchronizable) domain.
        KeychainService.resaveAllSynchronizable()

        // 3. Map legacy cadence → UpdateInterval (read raw keys via injected settings' helpers;
        //    the iCloudSyncEnabled/isPassiveDevice/backgroundInterval properties are gone).
        if settings.legacyBool("settings.isPassiveDevice") {
            settings.updateInterval = .off
        } else if settings.legacyHas("settings.backgroundInterval") {
            settings.updateInterval = .nearest(toSeconds: settings.legacyDouble("settings.backgroundInterval"))
        }

        // 4. Mirror current synced prefs into KVS.
        SettingsCloudSync.push(settings)

        settings.hasMigratedToNativeCloudKit = true

        // 5. Collapse any duplicates introduced by the merge of the old and new libraries.
        LibraryDedup.run(container: container)
    }
}
