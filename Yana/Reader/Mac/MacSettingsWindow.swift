import SwiftUI

#if targetEnvironment(macCatalyst)

/// The Mac Settings window: a System-Settings-style two-pane layout. The sidebar lists the
/// `SettingsPane`s; the detail shows the selected pane. Each pane reuses the same section views as
/// the iOS Form, regrouped for the desktop.
struct MacSettingsWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPane? = .general
    @State private var settings = AppSettings()
    /// Set by `onRevealDiagnostics` the moment the version row's five-tap gesture unlocks
    /// diagnostics. `AboutSettingsSection` flips `diagnosticsUnlocked` on its *own* `AppSettings`
    /// instance, so this window's separate instance is never told to re-observe that change — only
    /// a mutation to this window's own `@State` is guaranteed to trigger a re-render here. Gating
    /// `visiblePanes` on this in addition to `settings.diagnosticsUnlocked` makes the reveal take
    /// effect immediately by construction, not by relying on the `selection` assignment happening
    /// to re-render the body for the right reason.
    @State private var diagnosticsRevealed = false

    /// Diagnostics is hidden until the version row in About is tapped five times, so the sidebar is
    /// built from this rather than `allCases`. The rule itself lives in `DiagnosticsReveal` so both
    /// settings hosts share one tested implementation.
    private var visiblePanes: [SettingsPane] {
        DiagnosticsReveal.visiblePanes(
            unlocked: settings.diagnosticsUnlocked,
            revealed: diagnosticsRevealed
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visiblePanes) { pane in
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
                NotificationsSettingsSection()
                LibrarySettingsSection()
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
                AboutSettingsSection(
                    onRestartOnboarding: {
                        openWindow(id: WindowID.welcome, value: true)
                        dismiss()
                    },
                    onShowServerNotice: {
                        openWindow(id: WindowID.serverNotice, value: true)
                        dismiss()
                    },
                    onRevealDiagnostics: {
                        diagnosticsRevealed = true
                        selection = .diagnostics
                    }
                )
            }
        case .diagnostics:
            SyncLogView(onHideDiagnostics: {
                settings.diagnosticsUnlocked = false
                diagnosticsRevealed = false
                selection = .about
            })
        }
    }
}

#endif
