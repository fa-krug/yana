import SwiftUI
import WebKit

/// Hosts the server's own feed/tag/settings web UI, reusing the pairing flow's persistent
/// cookie session (`WKWebsiteDataStore.default()`) so a user who just paired via
/// `DevicePairingView` isn't asked to log in again to reach these pages.
struct ManagementWebView: View {
    let serverBaseURL: URL
    var path: String = "/feeds"

    var body: some View {
        ManagementWKWebView(url: serverBaseURL.appendingPathComponent(path))
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ManagementWKWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        // Non-ephemeral `.default()` data store — the same one `DevicePairingView` used to
        // establish the login session, so the cookies it set are already present here.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
