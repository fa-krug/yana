import Foundation
import WebKit

/// Decides whether a WebView navigation must leave the reader and open in the in-app browser.
///
/// This mirrors NetNewsWire's `WebViewController` policy: the decision keys solely off the
/// navigation *type*. Only `.linkActivated` (a link the user tapped) leaves the reader; the article
/// load itself, image-scheme requests, embeds and any other navigation are reported as `.other`
/// and load in place. Keying off the URL's origin is wrong — relative links may resolve against the
/// document's own base URL, which earlier mistook them for our own content.
enum ReaderLinkPolicy {
    static func opensExternally(url: URL, navigationType: WKNavigationType) -> Bool {
        guard navigationType == .linkActivated else { return false }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel":
            return true
        default:
            return false
        }
    }
}
