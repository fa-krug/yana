import SwiftUI

/// Source/issue links, NetNewsWire credit, the app version, and the "show welcome screen again"
/// restart action.
struct AboutSettingsSection: View {
    var onRestartOnboarding: () -> Void = {}
    var onShowServerNotice: () -> Void = {}

    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            LabeledContent("Version", value: AppInfo.versionDisplay)
                .accessibilityIdentifier("settings.version")
            Link(destination: URL(string: "https://github.com/fa-krug/yana")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.tintedIcon(.gray))
            }
            Link(destination: URL(string: "https://github.com/fa-krug/yana/issues")!) {
                Label("Suggest a Source or Report an Issue", systemImage: "exclamationmark.bubble")
                    .labelStyle(.tintedIcon(.green))
            }
            Link(destination: URL(string: "https://netnewswire.com")!) {
                Label("Reader View Inspired by NetNewsWire", systemImage: "heart")
                    .labelStyle(.tintedIcon(.pink))
            }
            Button {
                settings.hasCompletedOnboarding = false
                onRestartOnboarding()
            } label: {
                Label("Show Welcome Screen Again", systemImage: "sparkles")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.showWelcome")
            if ServerMigrationEligibility.canRestore(isPreServerMigrationUser: settings.isPreServerMigrationUser) {
                Button {
                    settings.hasDismissedServerMigrationNotice = false
                    onShowServerNotice()
                } label: {
                    Label("Server Update Notice", systemImage: "server.rack")
                        .labelStyle(.tintedIcon(.blue))
                }
                .accessibilityIdentifier("settings.showServerNotice")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Yana is free and open source. The list of built-in sources grows from what people ask for, so suggest one on the issue board. Thanks to the NetNewsWire team, whose clean reader view shaped how articles look here.")
        }
    }
}
