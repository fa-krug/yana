import SwiftUI

/// Stable identifiers for the Mac (Mac Catalyst) auxiliary windows opened via `openWindow`.
///
/// The feed editor is deliberately NOT here: editing pushes inside the Settings window (like the
/// Tags pane) and creating presents a sheet (like Add Tag), so it needs no window of its own.
enum WindowID {
    static let settings = "settings"
    static let welcome = "welcome"
}

/// The panes of the Mac two-pane Settings window sidebar, in display order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, feeds, tags, integrations, ai, about, diagnostics

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .reader: "Reader"
        case .feeds: "Feeds"
        case .tags: "Tags"
        case .integrations: "Integrations"
        case .ai: "AI"
        case .about: "About"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .reader: "textformat"
        case .feeds: "list.bullet.rectangle"
        case .tags: "tag"
        case .integrations: "puzzlepiece.extension"
        case .ai: "sparkles"
        case .about: "info.circle"
        case .diagnostics: "stethoscope"
        }
    }
}
