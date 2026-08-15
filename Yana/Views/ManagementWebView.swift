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
    @State private var diagnostic: ManagementWebViewDiagnostic?

    var body: some View {
        Group {
            if let diagnostic {
                ManagementWebViewFailureView(diagnostic: diagnostic) {
                    self.diagnostic = nil
                    self.loadURL = nil
                    Task { await resolveLoadURL() }
                }
            } else if let loadURL {
                ManagementWKWebView(url: loadURL, diagnostic: $diagnostic)
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
            ManagementWebViewLog.record("not paired -- loading \(path) directly, no bootstrap")
            loadURL = serverBaseURL.appendingPathComponent(path)
            return
        }
        let resolved = await Self.loadURL(serverBaseURL: serverBaseURL, path: path) {
            do {
                let bootstrap: WebviewSessionToken = try await client.post("/api/v1/auth/webview-session-token")
                ManagementWebViewLog.record("bootstrap token minted")
                return bootstrap.token
            } catch {
                ManagementWebViewLog.record("bootstrap mint FAILED: \(error)")
                throw error
            }
        }
        ManagementWebViewLog.record("loading \(resolved.redactingToken)")
        loadURL = resolved
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
    @Binding var diagnostic: ManagementWebViewDiagnostic?

    /// Tracks the last URL this representable itself asked the `WKWebView` to load -- deliberately
    /// distinct from the web view's own live `.url`, which changes on every in-page navigation
    /// (including the server's own redirect away from the single-use bootstrap URL once it's
    /// consumed). Comparing against the live URL would make `updateUIView` re-load the already-spent
    /// bootstrap token on the next unrelated SwiftUI re-render, permanently failing.
    ///
    /// Also the `WKNavigationDelegate`: without one, every navigation failure (TLS rejection, DNS,
    /// a 4xx/5xx body, a content-process crash) renders as a blank white web view with the
    /// underlying `Error` discarded -- indistinguishable from "the page really is blank," and
    /// undebuggable from a screenshot. Each callback here records what happened so
    /// `ManagementWebViewFailureView` can show it instead of nothing.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var requestedURL: URL?
        let onDiagnostic: (ManagementWebViewDiagnostic) -> Void

        init(onDiagnostic: @escaping (ManagementWebViewDiagnostic) -> Void) {
            self.onDiagnostic = onDiagnostic
        }

        /// Receives `window.onerror` / `unhandledrejection` from `ManagementWebViewProbe.script`.
        /// A page that throws during hydration is unmounted by React's error boundary and renders
        /// as a blank white document with a 200 status and a successful `didFinish` -- so neither
        /// the navigation delegate above nor a screenshot can see it. This is the only channel
        /// that can.
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String else { return }
            ManagementWebViewLog.record("js: \(body)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse {
                ManagementWebViewLog.record("response \(http.statusCode) for \(http.url?.redactingToken ?? "?")")
                if http.statusCode >= 400 {
                    onDiagnostic(
                        ManagementWebViewDiagnostic(
                            summary: String(localized: "The server returned an error."),
                            detail: "HTTP \(http.statusCode) -- \(http.url?.redactingToken ?? "?")"
                        )
                    )
                }
            }
            decisionHandler(.allow)
        }

        /// Checks whether the finished page actually rendered anything. "Loaded successfully and
        /// is blank" is the failure mode a navigation delegate alone cannot distinguish from
        /// "loaded successfully," and it is what a client-side render error looks like.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ManagementWebViewLog.record("finished \(webView.url?.redactingToken ?? "?")")
            webView.evaluateJavaScript(ManagementWebViewProbe.renderedContentCheck) { [weak self] result, _ in
                guard let self, let report = result as? String else { return }
                ManagementWebViewLog.record("dom: \(report)")
                guard report.hasPrefix("empty") else { return }
                self.onDiagnostic(
                    ManagementWebViewDiagnostic(
                        summary: String(localized: "The page loaded but did not display anything."),
                        detail: report
                    )
                )
            }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            report(error, phase: "provisional")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error, phase: "navigation")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ManagementWebViewLog.record("web content process terminated")
            onDiagnostic(
                ManagementWebViewDiagnostic(
                    summary: String(localized: "The page stopped responding."),
                    detail: "web content process terminated"
                )
            )
        }

        /// `NSURLErrorCancelled` is not a failure: it is what a redirect away from a page (the
        /// server's own 302 off the bootstrap URL) and a view dismissed mid-load both report.
        /// Surfacing it would put an error screen over a load that is actually still progressing.
        private func report(_ error: Error, phase: String) {
            let nsError = error as NSError
            // The URL WebKit was actually trying to reach when it failed -- distinct from the URL
            // this representable asked it to load, since a same-origin redirect (the server's own
            // 302 off the bootstrap token, or `/login?next=...`) can fail on a *later* hop this
            // code never explicitly requested. `WebKitErrorCannotUseRestrictedPort` in particular
            // is a client-side pre-connect block on the port in that URL, not a network failure,
            // so seeing which URL tripped it is the only way to know which hop carries the bad port.
            let failingURL = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                .flatMap { URL(string: $0) }?.redactingToken
                ?? (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.redactingToken
            ManagementWebViewLog.record(
                "\(phase) failed: \(nsError.domain) \(nsError.code) -- \(nsError.localizedDescription)"
                    + (failingURL.map { " -- failing URL: \($0)" } ?? " -- no failing URL in userInfo")
            )
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            onDiagnostic(
                ManagementWebViewDiagnostic(
                    summary: error.localizedDescription,
                    detail: "\(nsError.domain) \(nsError.code) (\(phase))"
                        + (failingURL.map { "\n\($0)" } ?? "")
                )
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        // `$diagnostic` is captured once, at coordinator-creation time; a `Binding` onto `@State`
        // stays valid for the lifetime of the view's storage, which outlives this web view.
        let binding = $diagnostic
        return Coordinator { value in
            MainActor.assumeIsolated { binding.wrappedValue = value }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(context.coordinator, name: ManagementWebViewProbe.messageHandlerName)
        config.userContentController.addUserScript(
            WKUserScript(
                source: ManagementWebViewProbe.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        // Lets Safari's Develop menu attach to this web view on a connected device, which is the
        // only way to read the page's own console/network state from outside the app.
        webView.isInspectable = true
        #endif
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

/// The JavaScript half of the instrumentation. Kept as plain strings rather than a bundled `.js`
/// resource so the whole diagnostic path stays readable in one file.
enum ManagementWebViewProbe {
    static let messageHandlerName = "yanaDiagnostics"

    /// Forwards uncaught errors and rejected promises to the native side. Injected at
    /// `.atDocumentStart` so it is installed before the page's own scripts run -- injected any
    /// later and the hydration error this exists to catch has already been thrown and lost.
    static let script = """
    (function () {
      function send(message) {
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage(String(message));
        } catch (ignored) {}
      }
      window.addEventListener('error', function (event) {
        send('error: ' + (event.message || '?') + ' @ ' + (event.filename || '?') + ':' + (event.lineno || 0));
      });
      window.addEventListener('unhandledrejection', function (event) {
        send('unhandledrejection: ' + ((event.reason && event.reason.message) || event.reason || '?'));
      });
    })();
    """

    /// Reports whether the document rendered anything, as `empty ...` or `ok ...`. Deliberately a
    /// text-and-element-count check rather than a pixel check: a React tree unmounted by an error
    /// boundary leaves a body that still exists and still has layout, but holds no content.
    static let renderedContentCheck = """
    (function () {
      var body = document.body;
      if (!body) { return 'empty (no body) title=' + document.title; }
      var text = (body.innerText || '').trim();
      var elements = body.getElementsByTagName('*').length;
      var state = (text.length === 0 && elements < 5) ? 'empty' : 'ok';
      return state + ' textLength=' + text.length + ' elements=' + elements +
        ' title=' + JSON.stringify(document.title) + ' path=' + location.pathname;
    })();
    """
}

/// One captured navigation failure, shown in place of the blank web view.
struct ManagementWebViewDiagnostic: Equatable, Sendable {
    let summary: String
    /// The machine-readable part (error domain/code, HTTP status, URL) -- what actually makes a
    /// report actionable, since `localizedDescription` alone rarely distinguishes causes.
    let detail: String
}

/// An in-memory ring of the last few navigation events, shown under the failure message. The
/// interesting part of this bug is the *sequence* (was a token minted? which URL loaded? did the
/// server redirect?), which a single terminal error does not convey.
enum ManagementWebViewLog {
    private static let limit = 12
    nonisolated(unsafe) private static var entries: [String] = []
    private static let lock = NSLock()

    static func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(message)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    static var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}

private extension URL {
    /// The bootstrap token is a live credential -- never put it in a log line or an on-screen
    /// diagnostic, both of which a user may paste into an issue report.
    var redactingToken: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return absoluteString }
        components.queryItems = items.map {
            $0.name == "token" ? URLQueryItem(name: "token", value: "<redacted>") : $0
        }
        return components.url?.absoluteString ?? absoluteString
    }
}

private struct ManagementWebViewFailureView: View {
    let diagnostic: ManagementWebViewDiagnostic
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(diagnostic.summary, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(diagnostic.detail)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(ManagementWebViewLog.transcript)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
