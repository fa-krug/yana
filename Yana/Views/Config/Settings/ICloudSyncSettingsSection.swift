import SwiftUI

/// iCloud sync toggle (config + articles) plus the opt-in passive-device mirror flag.
struct ICloudSyncSettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.iCloudSyncEnabled },
                set: { newValue in
                    settings.iCloudSyncEnabled = newValue
                    KeychainService.migrateSynchronizable(to: newValue)
                    if newValue {
                        Task {
                            await ConfigSyncService.shared.start()
                            await ConfigSyncService.shared.push()
                            await ArticleSyncService.shared.pull()
                            if !settings.isPassiveDevice { await ArticleSyncService.shared.pushAll() }
                        }
                    } else {
                        ConfigSyncService.shared.stop()
                    }
                }
            )) {
                Label(String(localized: "Sync via iCloud"), systemImage: "icloud")
                    .labelStyle(.tintedIcon(.blue))
            }
            if settings.iCloudSyncEnabled {
                Toggle(isOn: Binding(
                    get: { settings.isPassiveDevice },
                    set: { settings.isPassiveDevice = $0 }
                )) {
                    Label(String(localized: "Passive Device"), systemImage: "icloud.and.arrow.down")
                        .labelStyle(.tintedIcon(.blue))
                }
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Syncs feeds, tags, settings, API keys, and full articles (including images) across your devices via iCloud.")
                if settings.iCloudSyncEnabled {
                    Text("A passive device never fetches in the background and relies on iCloud for its articles.")
                }
                if settings.iCloudSyncEnabled, let error = ConfigSyncService.shared.lastSyncError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                if settings.iCloudSyncEnabled, let error = ArticleSyncService.shared.lastSyncError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
    }
}
