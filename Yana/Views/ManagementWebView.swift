import SwiftUI
import WebKit

/// Hosts the server's own feed/tag/settings web UI. Every time this view appears it bootstraps a
/// fresh browser session for the server via `POST /api/v1/auth/webview-session-token` (a
/// Bearer-authenticated, short-lived, single-use token) and loads the resulting
/// `GET /webview-session?token=...&next=...` URL, which the server exchanges for a real session
/// cookie. This replaced a one-shot cookie copy from `ASWebAuthenticationSession`'s shared cookie
/// jar into `WKWebsiteDataStore.default()`, done once at pairing time -- that approach never
/// reliably reached this WebView's cookie store on Mac Catalyst (App Sandbox isolates the app's
/// `HTTPCookieStorage.shared` from the system's out-of-process Safari auth agent that
/// `ASWebAuthenticationSession` runs through there), and even on iOS it could go stale over time
/// since it was never refreshed after the initial pairing. See
/// `docs/superpowers/plans/2026-08-11-webview-session-bootstrap-client.md`.
struct ManagementWebView: View {
    let serverBaseURL: URL
    var path: String = "/feeds"
    var title: LocalizedStringKey = "Manage"

    @State private var loadURL: URL?

    var body: some View {
        Group {
            if let loadURL {
                ManagementWKWebView(url: loadURL)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolveLoadURL() }
    }

    /// Falls back to loading `path` directly -- today's pre-bootstrap behavior -- on any failure
    /// to mint a bootstrap token (not paired, offline, server error), so a network blip never
    /// leaves this screen stuck on a spinner. That fallback may itself show the server's login
    /// page if there is no valid session at all, exactly as before this change.
    private func resolveLoadURL() async {
        let fallbackURL = serverBaseURL.appendingPathComponent(path)
        guard let client = AuthenticatedClient.current() else {
            loadURL = fallbackURL
            return
        }
        do {
            let bootstrap: WebviewSessionToken = try await client.post("/api/v1/auth/webview-session-token")
            loadURL = Self.webviewSessionURL(serverBaseURL: serverBaseURL, token: bootstrap.token, next: path)
        } catch {
            loadURL = fallbackURL
        }
    }

    static func webviewSessionURL(serverBaseURL: URL, token: String, next: String) -> URL {
        var components = URLComponents(
            url: serverBaseURL.appendingPathComponent("webview-session"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "next", value: next),
        ]
        return components.url!
    }
}

private struct ManagementWKWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
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
