import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
import SafariServices
#endif

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
    ///
    /// **The macOS branch is a genuinely smaller function, not a port with pieces missing.** Neither
    /// half of the iOS behavior exists there: `NSWorkspace` has no `universalLinksOnly` option
    /// (macOS resolves an installed app's claim on a URL itself, inside `open(_:)`, with the user's
    /// default-handler choice as the tiebreak), and there is no `SFSafariViewController`, so there is
    /// no in-app browser for `useSystemBrowser` to select against. `ReaderSettingsSection` already
    /// hides that toggle on the Mac for the same reason. Both parameters are kept in the signature
    /// and ignored so the two call sites stay unforked.
    #if os(macOS)
    @MainActor
    static func openExternally(_ url: URL, useSystemBrowser: Bool,
                               presenter: @escaping () -> PlatformViewController?) {
        _ = useSystemBrowser
        _ = presenter
        NSWorkspace.shared.open(url)
    }
    #else
    @MainActor
    static func openExternally(_ url: URL, useSystemBrowser: Bool,
                               presenter: @escaping () -> PlatformViewController?) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url); return
        }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { didOpen in
            guard !didOpen else { return }
            if useSystemBrowser {
                UIApplication.shared.open(url)
            } else if let presenter = presenter() {
                let safari = SFSafariViewController(url: url)
                // Present as a page sheet, the same card the "Open on Server" and progress sheets
                // use, so the browser can be pulled down to dismiss like every other sheet in the
                // app. A `.fullScreen` (or `.overFullScreen`) cover has no swipe-down gesture, only
                // the Done button.
                //
                // It must not be `.fullScreen` for a second reason: that presentation makes UIKit
                // detach the reader's views from the window once the transition completes, so iOS
                // reclaims the off-screen pages' layer backing and TextKit glyph layout while the
                // browser's WKWebView runs on top, leaving the next swipe to rebuild that layout
                // synchronously under the user's finger (the "can't instantly swipe after returning
                // from the web view" lag). A page sheet, like the `.overFullScreen` cover it
                // replaced, keeps the reader (the visible page and its prewarmed ±1 neighbors)
                // alive in the hierarchy behind the browser, so nothing is reloaded on return.
                safari.modalPresentationStyle = .pageSheet
                presenter.present(safari, animated: true)
            }
        }
    }
    #endif
}
