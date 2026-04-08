import SwiftUI
import WebKit

struct ArticleWebView: UIViewRepresentable {
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let css = """
            <style>
                :root {
                    color-scheme: light dark;
                }
                body {
                    font-family: -apple-system, system-ui;
                    font-size: 17px;
                    line-height: 1.6;
                    padding: 0 16px;
                    margin: 0;
                    color: var(--text-color);
                    background: transparent;
                }
                @media (prefers-color-scheme: dark) {
                    :root { --text-color: #f0f0f0; }
                }
                @media (prefers-color-scheme: light) {
                    :root { --text-color: #1a1a1a; }
                }
                img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 8px;
                }
                a {
                    color: #007AFF;
                }
                pre, code {
                    overflow-x: auto;
                    font-size: 14px;
                }
                blockquote {
                    border-left: 3px solid #888;
                    margin-left: 0;
                    padding-left: 16px;
                    opacity: 0.85;
                }
            </style>
        """

        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
                \(css)
            </head>
            <body>
                \(htmlContent)
            </body>
            </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
    }
}
