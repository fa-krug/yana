import WebKit

/// Shared WebKit plumbing for the reader. Both the live page (`ReaderWebViewController`) and the
/// launch warmer (`ReaderWarmup`) build their web views through `makeConfiguration()` so a warmed
/// web view is byte-for-byte adoptable by a page.
@MainActor
enum ReaderWebView {
    /// Shared across every reader page so the web views run in one Web Content process instead of
    /// spawning one each. The reader prewarms several pages at once, so without a shared pool a
    /// single swipe burst would fork ~10 processes — costly to start and memory-heavy. Sharing the
    /// pool also shares the page cache.
    static let processPool = WKProcessPool()

    /// One stateless image handler for all pages (it only reads from `ImageStore.shared`).
    static let imageSchemeHandler = ImageSchemeHandler()

    /// Configuration with the shared process pool, image scheme handler, and the link-interception
    /// userscript. The per-page `linkClickedHandler` message handler is NOT added here: it is weakly
    /// tied to a view controller, so each page adds its own after obtaining the web view (the warmer
    /// has no view controller, so it leaves the handler off until a page adopts the view).
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.setURLSchemeHandler(imageSchemeHandler, forURLScheme: ReaderWeb.imageScheme)
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: ReaderWeb.linkInterceptionScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        config.userContentController = controller
        return config
    }
}
