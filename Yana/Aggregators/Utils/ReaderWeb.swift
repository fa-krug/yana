import Foundation

/// Stable values shared by the aggregation pipeline and the reader WebView.
enum ReaderWeb {
    /// The WebView renders article HTML under this fixed base origin (used by embeds' `origin` param).
    static let baseOrigin = "https://app.yana.local"
    /// Custom URL scheme for locally cached images (served by ImageSchemeHandler).
    static let imageScheme = "yana-img"

    /// Base URL the reader loads article HTML against — the app bundle's resource directory, mirroring
    /// NetNewsWire's `ArticleRenderer.page.baseURL`. A `file://` base (rather than a fake web origin)
    /// keeps tapped links classified as `.linkActivated` so they open in the in-app browser.
    static let pageBaseURL: URL = {
        if let page = Bundle.main.url(forResource: "page", withExtension: "html") {
            return page.deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }()
}
