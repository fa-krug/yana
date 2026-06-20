import Foundation
import WebKit
import UIKit
import SafariServices

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
        return externalURL(fromClickedHref: url.absoluteString) != nil
    }

    /// The primary link path: an injected click handler intercepts taps at the DOM level and posts
    /// the browser-resolved absolute `href`. WebKit does not reliably report tapped links inside a
    /// `loadHTMLString`-rendered document as `.linkActivated` (they arrive as `.other` and would
    /// otherwise load in place), so click interception — not the navigation delegate — is the
    /// reliable signal. Returns the URL to open for http(s)/mailto/tel, or nil to ignore.
    static func externalURL(fromClickedHref href: String) -> URL? {
        guard let url = URL(string: href) else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel":
            return url
        default:
            return nil
        }
    }

    /// Opens a link the way a tapped article link does: first ask iOS whether an installed app claims
    /// this URL as a universal link (e.g. a YouTube/Reddit link opens that app), and only fall back to
    /// the in-app Safari view (or the system browser, per the user setting) when no app handles it.
    /// Shared by the in-article link handler and the reader's "Open in Browser" toolbar action so both
    /// behave the same. `presenter` is evaluated lazily after the universal-link check, since the
    /// in-app Safari view must be presented from the top-most controller in the window.
    @MainActor
    static func openExternally(_ url: URL, useSystemBrowser: Bool, presenter: @escaping () -> UIViewController?) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url); return
        }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { didOpen in
            guard !didOpen else { return }
            if useSystemBrowser {
                UIApplication.shared.open(url)
            } else if let presenter = presenter() {
                presenter.present(SFSafariViewController(url: url), animated: true)
            }
        }
    }
}
