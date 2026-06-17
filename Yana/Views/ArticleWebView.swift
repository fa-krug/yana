import SwiftUI
import UIKit
import WebKit

/// Renders a full article (header + body) as a single web document in a `WKWebView` that
/// owns its own vertical scrolling and pinch-to-zoom — mirroring NetNewsWire's reader, where
/// the title/feed/byline/date live in the HTML so the whole article scrolls and zooms as one.
/// When `onRefresh` is supplied, a `UIRefreshControl` is attached for pull-to-refresh.
struct ArticleWebView: UIViewRepresentable {
    let article: Article
    /// Optional pull-to-refresh trigger. `nil` (the default) means no refresh control.
    /// Fire-and-forget: the control retracts immediately instead of spinning until the
    /// refresh completes, so the work runs in the background while a separate indicator shows.
    var onRefresh: (() -> Void)?
    /// When the reader shows the article full-bleed (drawing under the floating bars), this
    /// insets the scrollable content so the article clears those bars while still scrolling
    /// beneath them. `nil` (the default) keeps the system's automatic inset adjustment, used
    /// by the search detail screen.
    var readerContentInset: UIEdgeInsets?

    private static let css = """
        <style>
            :root { color-scheme: light dark; }
            body {
                font-family: -apple-system, system-ui;
                font-size: 17px; line-height: 1.6;
                padding: 0 16px; margin: 0;
                color: var(--text-color); background: transparent;
            }
            @media (prefers-color-scheme: dark) { :root { --text-color: #f0f0f0; } }
            @media (prefers-color-scheme: light) { :root { --text-color: #1a1a1a; } }
            img { max-width: 100%; height: auto; border-radius: 8px; }
            a { color: #007AFF; }
            pre, code { overflow-x: auto; font-size: 14px; }
            blockquote { border-left: 3px solid #888; margin-left: 0; padding-left: 16px; opacity: 0.85; }
            .youtube-embed-container, .dailymotion-embed-container {
                position: relative; width: 100%; padding-bottom: 56.25%; margin: 1em 0;
            }
            .youtube-embed-container iframe, .dailymotion-embed-container iframe {
                position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0;
            }
            .article-header h1 {
                font-size: 1.5em; font-weight: 700; line-height: 1.25; margin: 0.5em 0 0.4em;
            }
            .article-meta { font-size: 0.95em; margin-bottom: 0.4em; }
            .article-meta .feed { color: #007AFF; font-weight: 500; }
            .article-meta .sep { opacity: 0.4; }
            .article-meta .secondary { opacity: 0.6; }
            .article-header hr {
                border: none; border-top: 1px solid rgba(128, 128, 128, 0.3); margin: 0.6em 0 0.2em;
            }
        </style>
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var loadedHTML: String?
        var onRefresh: (() -> Void)?

        @objc func handleRefresh(_ control: UIRefreshControl) {
            // Kick off the refresh and retract the control right away — the actual update runs
            // in the background and reports progress through the reader's own indicator.
            onRefresh?()
            control.endRefreshing()
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ReaderWeb.imageScheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        if onRefresh != nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                context.coordinator,
                action: #selector(Coordinator.handleRefresh(_:)),
                for: .valueChanged
            )
            webView.scrollView.refreshControl = refreshControl
        }
        applyReaderInset(to: webView)
        return webView
    }

    /// Applies (or clears) the reader's explicit content inset. With a full-bleed reader the
    /// web view ignores the safe area, so the system's automatic adjustment reports nothing —
    /// we set the inset ourselves to keep the article clear of the floating bars.
    private func applyReaderInset(to webView: WKWebView) {
        guard let inset = readerContentInset else { return }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if webView.scrollView.contentInset != inset {
            webView.scrollView.contentInset = inset
            webView.scrollView.verticalScrollIndicatorInsets = inset
        }
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onRefresh = onRefresh
        applyReaderInset(to: webView)

        let document = fullHTML
        guard context.coordinator.loadedHTML != document else { return }
        context.coordinator.loadedHTML = document
        webView.loadHTMLString(document, baseURL: URL(string: ReaderWeb.baseOrigin))
    }

    // MARK: - HTML assembly

    /// The complete HTML document: header (title/meta) followed by the article body.
    private var fullHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            \(Self.css)
        </head>
        <body>
            \(headerHTML)
            \(article.content)
        </body>
        </html>
        """
    }

    private var headerHTML: String {
        let esc = ContentFormatter.escapeHTML
        var meta: [String] = []
        if let feedName = article.feed?.name, !feedName.isEmpty {
            meta.append("<span class=\"feed\">\(esc(feedName))</span>")
        }
        if !article.author.isEmpty {
            meta.append("<span class=\"secondary\">\(esc(article.author))</span>")
        }
        let dateString = article.date.formatted(date: .abbreviated, time: .shortened)
        meta.append("<span class=\"secondary\">\(esc(dateString))</span>")
        let metaHTML = meta.joined(separator: "<span class=\"sep\"> · </span>")

        return """
        <div class="article-header">
            <h1>\(esc(article.title))</h1>
            <div class="article-meta">\(metaHTML)</div>
            <hr>
        </div>
        """
    }
}
