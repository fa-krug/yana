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
        guard let article = StartupTrace.measure("ReaderWarmup.anchorFetch", {
            anchorArticle(savedIdentifier: settings.timelineAnchorIdentifier, in: context)
        }) else { return }

        // First access triggers the themes manager's one-time bundle scan + current-theme load.
        let theme = StartupTrace.measure("ArticleThemesManager.currentTheme") {
            ArticleThemesManager.shared.currentTheme
        }

        // summaryPending: false — a stored anchor at cold start has no in-flight AI summary job.
        let html = StartupTrace.measure("ReaderWarmup.renderHTML") {
            ArticleRenderer.fullPageHTML(
                article: article,
                theme: theme,
                textSize: settings.articleTextSize,
                summaryPending: false
            )
        }

        let webView = StartupTrace.measure("ReaderWarmup.makeWebView") {
            WKWebView(frame: .zero, configuration: ReaderWebView.makeConfiguration())
        }
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Start the document load immediately — it progresses (and fires `didFinish`) even before
        // the view is on-window, so kicking it as early as possible front-loads the parse.
        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
        // Parent off-screen in the key window so WebKit lays out + composites at the eventual page
        // width (making the adopted paint pixel-correct), without ever being visible. When the warm
        // runs before the scene has a key window (launch path), retry on the next runloop until one
        // exists; a page adopting the view first makes this a no-op (it then has a superview).
        parentOffScreen(webView)
        ReaderWarmupStore.shared.store(identifier: article.identifier, html: html, webView: webView)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap(\.keyWindow)
            .first
    }

    /// Parent the warmed web view off-screen in the key window for pixel-correct pre-paint. If no
    /// key window exists yet (warm kicked from `didFinishLaunching` before the scene connects),
    /// retry on the next runloop, bounded. No-op once the view has a superview — adoption parents
    /// it into the page, and re-adding it here must never fight that.
    private static func parentOffScreen(_ webView: WKWebView, retriesLeft: Int = 8) {
        guard webView.superview == nil else { return }
        if let window = keyWindow() {
            webView.frame = CGRect(x: 0, y: window.bounds.height,
                                   width: window.bounds.width, height: window.bounds.height)
            window.addSubview(webView)
            window.sendSubviewToBack(webView)
            return
        }
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.async { parentOffScreen(webView, retriesLeft: retriesLeft - 1) }
    }
}
