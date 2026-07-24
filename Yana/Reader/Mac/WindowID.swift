import SwiftData
import SwiftUI

/// Stable identifiers for the Mac (Mac Catalyst) auxiliary windows opened via `openWindow`.
enum WindowID {
    static let settings = "settings"
    static let welcome = "welcome"
    static let feedEditor = "feed-editor"
}

/// Which feed the feed-editor window edits. `.create` = a brand-new feed.
/// `PersistentIdentifier` is `Codable` + `Hashable`, so this is a valid `WindowGroup(for:)` value:
/// each distinct feed gets its own editor window, and every `.create` shares one.
enum FeedEditorTarget: Codable, Hashable {
    case create
    case edit(PersistentIdentifier)
}

/// The panes of the Mac two-pane Settings window sidebar, in display order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, feeds, tags, integrations, ai, about

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
        }
    }
}
