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

    /// The body point size from the user's Dynamic Type setting — exactly how NetNewsWire sizes
    /// its reader text (`UIFont.preferredFont(forTextStyle: .body).pointSize`, injected into the
    /// stylesheet). This makes the article respect the system "Textgröße" slider; a fixed px size
    /// would ignore it. Recomputed whenever the view re-renders (e.g. after a content-size change).
    private var css: String {
        let bodyPointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        return """
        <style>
            /* Colour variables ported from NetNewsWire's stylesheet.css (light defaults,
               dark overrides below) so the reader matches NNW's palette. */
            :root {
                color-scheme: light dark;
                font: -apple-system-body;
                font-size: \(bodyPointSize)px;
                --text-color: #1a1a1a;
                --primary-accent-color: #086AEE;
                --secondary-accent-color: #086AEE;
                --article-date-color: rgba(0, 0, 0, 0.5);
                --code-background-color: #eee;
                --code-color: #111;
                --rule-color: lightgray;
                --block-quote-border-color: rgba(0, 0, 0, 0.25);
            }
            @media (prefers-color-scheme: dark) {
                :root {
                    --text-color: #f0f0f0;
                    --primary-accent-color: #2D80F1;
                    --secondary-accent-color: #5E9EF4;
                    --article-date-color: rgba(255, 255, 255, 0.5);
                    --code-background-color: #333;
                    --code-color: #dcdcdc;
                    --rule-color: dimgray;
                    --block-quote-border-color: rgba(94, 158, 244, 0.75);
                }
            }
            body {
                font: -apple-system-body;
                font-size: \(bodyPointSize)px;
                line-height: 1.6;
                padding: 0 20px; margin: 0;
                color: var(--text-color); background: transparent;
                word-wrap: break-word;
                word-break: break-word;
                -webkit-hyphens: auto;
                -webkit-text-size-adjust: none;
            }
            a { color: var(--secondary-accent-color); text-decoration: none; }
            a:hover { text-decoration: underline; }
            img, figure, video { max-width: 100%; height: auto; margin: 0 auto; }
            img { border-radius: 8px; }
            figure { margin: 1em auto; }
            figcaption { margin-top: 0.5em; font-size: 0.85em; line-height: 1.3em; opacity: 0.7; }
            code, pre {
                font-family: ui-monospace, "SF Mono", Menlo, Courier, monospace;
                font-size: 0.85em;
                background: var(--code-background-color);
                color: var(--code-color);
                -webkit-hyphens: none;
            }
            code { padding: 1px 3px; border-radius: 3px; }
            pre { padding: 8px; border-radius: 6px; overflow-x: auto; }
            pre code { padding: 0; background: none; }
            blockquote {
                margin-inline-start: 0; margin-inline-end: 0;
                padding-inline-start: 15px;
                border-inline-start: 3px solid var(--block-quote-border-color);
            }
            hr { border: none; border-top: 1.5px solid var(--rule-color); }
            .youtube-embed-container, .dailymotion-embed-container {
                position: relative; width: 100%; padding-bottom: 56.25%; margin: 1em 0;
            }
            .youtube-embed-container iframe, .dailymotion-embed-container iframe {
                position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0;
            }
            /* Header — NNW's title + small-caps dateline treatment, on Yana's markup. */
            .article-header h1 {
                font-size: 1.5rem; font-weight: bold; line-height: 1.15; margin: 0 0 5px;
            }
            .article-meta {
                margin-bottom: 5px;
                font-weight: bold;
                font-variant-caps: all-small-caps;
                letter-spacing: 0.025em;
                color: var(--article-date-color);
            }
            .article-meta .feed { color: var(--secondary-accent-color); }
            .article-meta .sep { opacity: 0.5; }
            .article-meta .secondary { color: var(--article-date-color); }
            .article-header hr { margin: 10px 0 0; }
            /* Article body — NNW's .articleBody: spacing + accent-underlined links. */
            .article-body { margin-top: 20px; line-height: 1.6em; }
            .article-body a:link, .article-body a:visited {
                text-decoration: underline;
                text-decoration-color: var(--primary-accent-color);
                text-decoration-thickness: 1px;
                text-underline-offset: 2px;
                color: var(--secondary-accent-color);
            }
        </style>
        """
    }

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
            \(css)
        </head>
        <body>
            \(headerHTML)
            <div class="article-body">
                \(article.content)
            </div>
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
