import SwiftUI

/// iOS settings: a single scrolling Form. Feeds/Tags push detail screens; every other group is a
/// reusable section view shared with the Mac two-pane settings window.
struct SettingsScreenView: View {
    var onRestartOnboarding: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            organizeSection
            ReaderSettingsSection()
            RedditSettingsSection()
            YouTubeSettingsSection()
            NotificationsSettingsSection()
            AIProviderSettingsSection()
            AITuningSettingsSection()
            LibrarySettingsSection()
            ICloudSyncSettingsSection()
            AboutSettingsSection(onRestartOnboarding: {
                onRestartOnboarding()
                dismiss()
            })
        }
        // Keep the toggle control on the trailing edge (matching the row pickers). On Mac Catalyst
        // the default form Toggle is a leading checkbox, which sits before the row's tinted icon and
        // looks misaligned; a switch matches iOS (its default) and the trailing pickers.
        .toggleStyle(.switch)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
        }
        .onDisappear { ConfigSyncService.shared.requestPush() }
    }

    private var organizeSection: some View {
        Section {
            NavigationLink {
                FeedsView()
            } label: {
                Label("Feeds", systemImage: "list.bullet.rectangle")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.feeds")
            NavigationLink {
                TagsView()
            } label: {
                Label("Tags", systemImage: "tag")
                    .labelStyle(.tintedIcon(.pink))
            }
        } footer: {
            Text("Manage your feeds and the tags applied to articles.")
        }
    }
}
