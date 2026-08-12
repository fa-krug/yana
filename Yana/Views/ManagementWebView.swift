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
    /// to mint a bootstrap token (not paired, offline, server error) or if minting doesn't finish
    /// within `mintTokenTimeout`, so a network blip (or a hung/captive-portal connection) never
    /// leaves this screen stuck on a spinner. That fallback may itself show the server's login
    /// page if there is no valid session at all, exactly as before this change.
    private func resolveLoadURL() async {
        guard let client = AuthenticatedClient.current() else {
            loadURL = serverBaseURL.appendingPathComponent(path)
            return
        }
        loadURL = await Self.loadURL(serverBaseURL: serverBaseURL, path: path) {
            let bootstrap: WebviewSessionToken = try await client.post("/api/v1/auth/webview-session-token")
            return bootstrap.token
        }
    }

    /// Pure, testable core of `resolveLoadURL()`: given a way to mint a bootstrap token, returns
    /// the bootstrap URL on success, or `fallbackURL` (`serverBaseURL/path`) if `mintToken` throws
    /// or doesn't finish within `mintTokenTimeout`. Doesn't itself decide whether there's a client
    /// to mint a token with -- that "not paired" guard stays in `resolveLoadURL()`.
    static func loadURL(
        serverBaseURL: URL,
        path: String,
        mintTokenTimeout: Duration = .seconds(6),
        mintToken: @escaping @Sendable () async throws -> String
    ) async -> URL {
        let fallbackURL = serverBaseURL.appendingPathComponent(path)
        let token = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await mintToken()
            }
            group.addTask {
                try? await Task.sleep(for: mintTokenTimeout)
                return nil
            }
            defer { group.cancelAll() }
            for await result in group {
                return result
            }
            return nil
        }
        guard let token else {
            return fallbackURL
        }
        return webviewSessionURL(serverBaseURL: serverBaseURL, token: token, next: path)
    }

    // Force-unwrapped rather than returning `URL?`: `serverBaseURL` is always a URL already
    // validated at pairing time (never arbitrary user text at this call site), and appending a
    // literal path component plus two ASCII-safe query items to a valid URL cannot fail --
    // returning an optional here would only push a never-actually-nil case onto every caller.
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

    /// Tracks the last URL this representable itself asked the `WKWebView` to load -- deliberately
    /// distinct from the web view's own live `.url`, which changes on every in-page navigation
    /// (including the server's own redirect away from the single-use bootstrap URL once it's
    /// consumed). Comparing against the live URL would make `updateUIView` re-load the already-spent
    /// bootstrap token on the next unrelated SwiftUI re-render, permanently failing.
    final class Coordinator {
        var requestedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.requestedURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.requestedURL != url else { return }
        context.coordinator.requestedURL = url
        webView.load(URLRequest(url: url))
    }
}
