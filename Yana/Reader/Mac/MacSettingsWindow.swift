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
    @State private var settings = AppSettings()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                        // Merge the icon and text into ONE accessibility element before applying
                        // the identifier. Without this, SwiftUI propagates the identifier to every
                        // descendant, so a UI test's `firstMatch` resolves to the 15x12 SF Symbol
                        // image inside the row — which is not hittable, and clicking it fails.
                        // Combining also reads better under VoiceOver (one "Feeds" row rather than
                        // an icon followed by text).
                        .accessibilityElement(children: .combine)
                        // Screenshot/UI-test navigation target — pane titles are localized, the
                        // raw value is not.
                        .accessibilityIdentifier("mac.settings.pane.\(pane.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Settings")
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 460, ideal: 520)
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("mac.settings.window")
        .frame(minWidth: 700, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general:
            Form {
                ServerSettingsSection()
                NotificationsSettingsSection()
                LibrarySettingsSection()
            }
        case .reader:
            Form { ReaderSettingsSection() }
        case .manage:
            NavigationStack {
                ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!)
            }
        case .ai:
            Form { AIModeSettingsSection() }
        case .about:
            Form {
                AboutSettingsSection(
                    onRestartOnboarding: {
                        // Reset explicitly: a stale `.server` value from an earlier re-pairing
                        // trigger this session must not carry into a deliberate "Restart
                        // Onboarding" click and skip straight past the welcome/feature pages.
                        // Mirrors the iOS reset in ReaderHostView.swift.
                        appState.welcomeInitialStep = .welcome
                        openWindow(id: WindowID.welcome, value: true)
                        dismiss()
                    },
                    onShowServerNotice: {
                        openWindow(id: WindowID.serverNotice, value: true)
                        dismiss()
                    }
                )
            }
        }
    }
}

#endif
