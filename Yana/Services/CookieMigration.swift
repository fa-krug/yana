import Foundation
import WebKit

/// Bridges cookies from the shared jar `DevicePairingView`'s `ASWebAuthenticationSession` (non-
/// ephemeral) writes into, over to the `WKWebsiteDataStore` `ManagementWebView` reads from. iOS
/// treats these as two entirely separate cookie stores with no automatic sharing — without this
/// step, `ManagementWebView` would ask the user to sign in a second time immediately after they
/// just signed in during device pairing.
@MainActor
enum CookieMigration {
    static func copySharedCookies(for serverBaseURL: URL) async {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: serverBaseURL), !cookies.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
    }
}
