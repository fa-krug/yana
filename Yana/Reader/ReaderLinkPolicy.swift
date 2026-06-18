import Foundation
import WebKit

/// Decides whether a WebView navigation is a link the user followed — which must leave the reader
/// and open in the in-app browser — versus our own rendered content, which loads in place.
///
/// The decision keys off whether the caller *initiated* the load, not the navigation type or URL.
/// The reader programmatically loads exactly one main-frame document per article (via
/// `loadHTMLString`); the caller flags that load as `isExpectedArticleLoad`. Every other main-frame
/// navigation is a followed link. This is necessary because WebKit reports a tapped relative link
/// that resolves against the base origin (`https://app.yana.local/…`, when the article had no usable
/// `<base href>`) with navigationType `.other` — indistinguishable from the initial load by type or
/// URL alone, which is what made earlier origin/type heuristics fail.
enum ReaderLinkPolicy {
    static func opensExternally(url: URL, navigationType: WKNavigationType,
                                targetIsMainFrame: Bool,
                                isExpectedArticleLoad: Bool) -> Bool {
        // Locally cached images (served by ImageSchemeHandler) always load in place.
        if url.scheme == ReaderWeb.imageScheme { return false }
        // Subframe loads (e.g. video embeds) stay in place even though they are external URLs.
        guard targetIsMainFrame else { return false }
        // The reader's own programmatic article load stays in place.
        if isExpectedArticleLoad { return false }

        // Any other main-frame web navigation is a followed link.
        if url.scheme == "http" || url.scheme == "https" { return true }

        // Non-web schemes (mailto, tel, custom app links) leave the app only when tapped.
        return navigationType == .linkActivated
    }
}
