import Foundation
import WebKit

/// Decides whether a WebView navigation is a link the user followed — which must leave the reader
/// and open in the in-app browser — versus our own rendered content, which loads in place.
///
/// Classification keys off the *kind* of navigation rather than the URL's origin: the only
/// main-frame `http(s)` navigation the reader initiates is the initial article load
/// (`loadHTMLString`, reported as `.other` under the base origin). Everything else in the main
/// frame is a followed link. This is robust even when a relative link resolves against the base
/// origin (`https://app.yana.local/…`) because the article had no usable `<base href>`.
enum ReaderLinkPolicy {
    static func opensExternally(url: URL, navigationType: WKNavigationType,
                                targetIsMainFrame: Bool,
                                baseOrigin: String = ReaderWeb.baseOrigin) -> Bool {
        // Locally cached images (served by ImageSchemeHandler) always load in place.
        if url.scheme == ReaderWeb.imageScheme { return false }
        // Subframe loads (e.g. video embeds) stay in place even though they are external URLs.
        guard targetIsMainFrame else { return false }

        if url.scheme == "http" || url.scheme == "https" {
            let isInitialArticleLoad = navigationType == .other
                && url.absoluteString.hasPrefix(baseOrigin)
            return !isInitialArticleLoad
        }

        // Non-web schemes (mailto, tel, custom app links) leave the app only when tapped.
        return navigationType == .linkActivated
    }
}
