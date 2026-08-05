import SwiftUI

/// Stable identifiers for the Mac (Mac Catalyst) auxiliary windows opened via `openWindow`.
///
/// The feed editor is deliberately NOT here: editing pushes inside the Settings window (like the
/// Tags pane) and creating presents a sheet (like Add Tag), so it needs no window of its own.
enum WindowID {
    static let settings = "settings"
    static let welcome = "welcome"
    static let serverNotice = "serverNotice"
}

/// The panes of the Mac two-pane Settings window sidebar, in display order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, manage, ai, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .reader: "Reader"
        case .manage: "Manage Feeds & Tags"
        case .ai: "AI"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .reader: "textformat"
        case .manage: "list.bullet.rectangle"
        case .ai: "sparkles"
        case .about: "info.circle"
        }
    }
}
