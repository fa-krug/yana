import SwiftUI

#if os(macOS)

/// The Mac Settings window: a System-Settings-style two-pane layout. The sidebar lists the
/// `SettingsPane`s; the detail shows the selected pane. Each pane reuses the same section views as
/// the iOS Form, regrouped for the desktop.
struct MacSettingsWindow: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPane? = .general
    @Environment(AppSettings.self) private var settings

    /// The Manage pane hosts a WebView pointed at the paired server's own web UI — with no
    /// paired server there's nothing to load and the pane renders a blank white rectangle
    /// (see `ManagementWebView`), so hide it instead of showing that dead end.
    private var availablePanes: [SettingsPane] {
        let isPaired = AuthenticatedClient.current(settings: settings) != nil
        return SettingsPane.allCases.filter { $0 != .manage || isPaired }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(availablePanes) { pane in
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
            // `.sidebar` is what gives the column System Settings' own vibrant material. Without
            // it the list rendered on a plain (and, inside a `Settings` scene, see-through)
            // background, so the window behind it showed through the pane list.
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Settings")
            // A two-pane Settings window has nothing to collapse -- the pane list IS the window's
            // navigation -- but `NavigationSplitView` installs the toggle regardless, and it sat
            // alone above the rows looking like a stray control.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 460, ideal: 520)
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("mac.settings.window")
        .frame(minWidth: 700, minHeight: 560)
        .onAppear {
            if let restored = SettingsPane(rawValue: settings.macSettingsPane) { selection = restored }
            resetSelectionIfUnavailable()
        }
        .onChange(of: settings.serverBaseURL) { resetSelectionIfUnavailable() }
        .onChange(of: selection) { _, pane in
            settings.macSettingsPane = pane?.rawValue ?? ""
        }
    }

    private func resetSelectionIfUnavailable() {
        if let selection, !availablePanes.contains(selection) {
            self.selection = .general
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general:
            settingsForm {
                ServerSettingsSection()
                NotificationsSettingsSection()
                LibrarySettingsSection()
            }
        case .reader:
            settingsForm { ReaderSettingsSection() }
        case .manage:
            if availablePanes.contains(.manage) {
                NavigationStack {
                    ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!)
                }
            } else {
                settingsForm { ServerSettingsSection() }
            }
        case .ai:
            settingsForm { AIModeSettingsSection() }
        case .about:
            settingsForm {
                AboutSettingsSection(
                    onRestartOnboarding: {
                        // Reset explicitly: a stale `.server` value from an earlier re-pairing
                        // trigger this session must not carry into a deliberate "Restart
                        // Onboarding" click and skip straight past the welcome/feature pages.
                        // Mirrors the iOS reset in ReaderHostView.swift.
                        appState.welcomeInitialStep = .welcome
                        openWindow(id: WindowID.welcome)
                        dismiss()
                    },
                    onShowServerNotice: {
                        openWindow(id: WindowID.serverNotice)
                        dismiss()
                    }
                )
            }
        }
    }

    /// Every pane's form, with the two things a `Form` on macOS does not do on its own.
    ///
    /// **`.formStyle(.grouped)`** is what makes this read like System Settings: leading labels,
    /// trailing controls, grouped rows. The default macOS style is `.columns`, which right-aligns
    /// each label against a shared column edge -- that, plus the iOS icon tiles the shared sections
    /// used to draw (see `TintedIconLabelStyle`), is what left the panes looking jumbled.
    ///
    /// **`.scrollContentBackground(.visible)`** puts the window's own surface back behind the
    /// rows. A `Form` inside a `NavigationSplitView` detail column otherwise leaves its scroll
    /// background clear, so the Settings window rendered see-through onto whatever was behind it.
    /// Same call `../mysquad` makes on its Mac lists.
    @ViewBuilder
    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.visible)
    }
}

#endif
