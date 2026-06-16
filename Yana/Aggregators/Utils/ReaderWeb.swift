import Foundation

/// Stable values shared by the aggregation pipeline and the reader WebView.
enum ReaderWeb {
    /// The WebView renders article HTML under this fixed base origin (used by embeds' `origin` param).
    static let baseOrigin = "https://app.yana.local"
    /// Custom URL scheme for locally cached images (served by ImageSchemeHandler).
    static let imageScheme = "yana-img"
}
