import SwiftUI

#if targetEnvironment(macCatalyst)

/// The Mac Settings window: a System-Settings-style two-pane layout. The sidebar lists the
/// `SettingsPane`s; the detail shows the selected pane. Each pane reuses the same section views as
/// the iOS Form, regrouped for the desktop.
struct MacSettingsWindow: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Settings")
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 460, ideal: 520)
        }
        .toggleStyle(.switch)
        .frame(minWidth: 700, minHeight: 560)
        .onDisappear { ConfigSyncService.shared.requestPush() }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general:
            Form {
                NotificationsSettingsSection()
                LibrarySettingsSection()
                ICloudSyncSettingsSection()
            }
        case .reader:
            Form { ReaderSettingsSection() }
        case .feeds:
            NavigationStack { FeedsView() }
        case .tags:
            NavigationStack { TagsView() }
        case .integrations:
            Form {
                RedditSettingsSection()
                YouTubeSettingsSection()
            }
        case .ai:
            Form {
                AIProviderSettingsSection()
                AITuningSettingsSection()
            }
        case .about:
            Form {
                AboutSettingsSection(onRestartOnboarding: {
                    // Completed in Task 7: open the Welcome window, then close Settings.
                })
            }
        }
    }
}

#endif
