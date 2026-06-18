import Foundation

/// Stable values shared by the aggregation pipeline and the reader WebView.
enum ReaderWeb {
    /// The WebView renders article HTML under this fixed base origin (used by embeds' `origin` param).
    static let baseOrigin = "https://app.yana.local"
    /// Custom URL scheme for locally cached images (served by ImageSchemeHandler).
    static let imageScheme = "yana-img"

    /// Base URL the reader loads article HTML against — the app bundle's resource directory, mirroring
    /// NetNewsWire's `ArticleRenderer.page.baseURL`. A `file://` base (rather than a fake web origin)
    /// lets the article's own `<base href>` resolve relative links to the real site.
    static let pageBaseURL: URL = {
        if let page = Bundle.main.url(forResource: "page", withExtension: "html") {
            return page.deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }()

    /// Name of the `WKScriptMessageHandler` the link-interception script posts to.
    static let linkClickedHandler = "linkClicked"

    /// Injected at document start to capture link taps at the DOM level. WebKit does not reliably
    /// report tapped links inside a `loadHTMLString`-rendered document as `.linkActivated`, so the
    /// navigation delegate can't be trusted to catch them. A capturing click listener finds the
    /// enclosing `<a>`, reads its already-resolved absolute `href` (the browser resolves relative
    /// links against `<base href>`), and hands it to Swift. In-page fragment jumps (footnotes, etc.)
    /// and unsupported schemes are left to default behavior.
    static let linkInterceptionScript = """
    (function() {
      document.addEventListener("click", function(event) {
        var node = event.target;
        while (node && node.tagName !== "A") { node = node.parentElement; }
        if (!node || !node.href) { return; }
        // In-page anchor (only a fragment differs from the document base): let it scroll.
        if (node.hash && node.href.split("#")[0] === document.baseURI.split("#")[0]) { return; }
        var scheme = (node.protocol || "").replace(":", "").toLowerCase();
        if (scheme === "http" || scheme === "https" || scheme === "mailto" || scheme === "tel") {
          event.preventDefault();
          window.webkit.messageHandlers.linkClicked.postMessage(node.href);
        }
      }, true);
    })();
    """
}
