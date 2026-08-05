import SwiftUI
import WebKit

/// Drives the device-pairing flow: loads the server's login page in a **persistent**
/// (non-ephemeral) `WKWebView` so the resulting cookie session survives for the management
/// WebView to reuse later, and intercepts the `yana://auth-callback` redirect before it becomes
/// a network request.
struct DevicePairingView: View {
    let serverBaseURL: URL
    let onPaired: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            DevicePairingWebView(serverBaseURL: serverBaseURL, onPaired: onPaired, onFailed: onCancel)
                .navigationTitle("Sign In")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
    }
}

private struct DevicePairingWebView: UIViewRepresentable {
    let serverBaseURL: URL
    let onPaired: (String) -> Void
    let onFailed: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        // Non-ephemeral `.default()` data store — cookies from this session persist across
        // launches, and the management WebView (a later task) reuses the same store so a user
        // who just paired doesn't have to log in again.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        let session = DevicePairing.makeSession()
        context.coordinator.session = session
        let deviceName = UIDevice.current.name
        webView.load(URLRequest(url: DevicePairing.pairingURL(
            serverBaseURL: serverBaseURL, session: session, deviceName: deviceName
        )))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPaired: onPaired, onFailed: onFailed) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPaired: (String) -> Void
        let onFailed: () -> Void
        var session: DevicePairingSession?

        init(onPaired: @escaping (String) -> Void, onFailed: @escaping () -> Void) {
            self.onPaired = onPaired
            self.onFailed = onFailed
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, url.scheme == "yana", let session else {
                decisionHandler(.allow)
                return
            }
            switch DevicePairing.handleCallback(url, session: session) {
            case .success(let token):
                decisionHandler(.cancel)
                onPaired(token)
            case .stateMismatch, .malformedCallback:
                decisionHandler(.cancel)
                onFailed()
            }
        }
    }
}
