import SwiftUI
import WebKit

/// Read-only WKWebView that renders article HTML exactly like the reader — same `ArticleRenderer`
/// output, theme, text size, and `yana-img://` scheme handler so locally cached images load.
/// Used by the custom-script editor's preview. Reloads only when the HTML actually changes.
struct ScriptPreviewWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var loaded: String? }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ReaderWeb.imageScheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
    }
}
