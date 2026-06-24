import SwiftData
import UIKit
import WebKit

/// Single-slot holder for the warmed anchor web view, parked between launch warmup and the first
/// reader page adopting it. Thin concrete wrapper over `WarmupSlotBox<WKWebView>`.
@MainActor
final class ReaderWarmupStore {
    static let shared = ReaderWarmupStore()
    private let box = WarmupSlotBox<WKWebView>()

    func store(identifier: String, html: String, webView: WKWebView) {
        box.store(identifier: identifier, html: html, payload: webView)
    }

    /// Single-use: returns the warmed web view on an identifier + HTML match and clears the slot.
    func take(identifier: String, html: String) -> WKWebView? {
        box.take(identifier: identifier, html: html)
    }

    /// Release a warmed view no page adopted (e.g. the saved anchor was filtered out and a
    /// different article opened first): detach it from the off-screen warm host and clear the slot.
    func discardUnused() {
        box.discardUnused()?.removeFromSuperview()
    }
}

/// Pre-renders the saved anchor article into an off-screen `WKWebView` during launch so the Web
/// Content process spawn + first-document parse + paint happen before the reader's first page is
/// created. The first `ReaderWebViewController` adopts the warmed view when its rendered HTML
/// matches (see `ReaderWebViewController.viewDidLoad`).
@MainActor
enum ReaderWarmup {

    /// The article the reader will most likely open to: the saved anchor if it still exists,
    /// otherwise the newest article (the reader's default when there is no anchor).
    static func anchorArticle(savedIdentifier: String?, in context: ModelContext) -> Article? {
        if let savedIdentifier,
           let article = ArticleResolution.fetchByIdentifier(savedIdentifier, in: context) {
            return article
        }
        return ArticleResolution.fetchNewest(in: context)
    }

    /// Kicked from the scene `.task` before `articleStore.start()`. Returns immediately after
    /// kicking off the async web-view load; the WebKit work proceeds on its own.
    static func start() {
        let context = AppContainer.shared.mainContext
        let settings = AppSettings()
        guard let article = anchorArticle(savedIdentifier: settings.timelineAnchorIdentifier,
                                          in: context) else { return }

        // summaryPending: false — a stored anchor at cold start has no in-flight AI summary job.
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize,
            summaryPending: false
        )

        let webView = WKWebView(frame: .zero, configuration: ReaderWebView.makeConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Parent off-screen in the key window so WebKit lays out + composites at the eventual page
        // width (making the adopted paint pixel-correct), without ever being visible. Degrades to an
        // off-window warm (process + parse) if no key window exists yet — paint then completes on adopt.
        if let window = keyWindow() {
            webView.frame = CGRect(x: 0, y: window.bounds.height,
                                   width: window.bounds.width, height: window.bounds.height)
            window.addSubview(webView)
            window.sendSubviewToBack(webView)
        }

        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
        ReaderWarmupStore.shared.store(identifier: article.identifier, html: html, webView: webView)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap(\.keyWindow)
            .first
    }
}
