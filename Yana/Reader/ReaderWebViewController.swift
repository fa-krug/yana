import UIKit
import WebKit
import SafariServices

/// Hosts one article's `WKWebView`, pinned full-screen under the (opaque) bars so WKWebView's
/// automatic content-inset adjustment keeps the article clear of them. Ported/adapted from
/// NetNewsWire's WebViewController, trimmed of Account/extractor/search.
@MainActor
final class ReaderWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    let article: Article
    private let allowsFullscreen: Bool
    private let onRefresh: (() -> Void)?
    private let onRequestShowBars: () -> Void

    private var webView: WKWebView!
    private var loadedHTML: String?
    /// Cold-start instrumentation: whether this page adopted the launch-warmed web view.
    private var adoptedWarmedView = false
    /// Cold-start instrumentation: true only for the very first reader page (the anchor), so the
    /// `anchorVisible` marker isn't stolen by a prewarmed neighbor that paints first.
    private var isColdStartAnchorPage = false

    var summaryPending = false { didSet { if summaryPending != oldValue { render() } } }

    private var topTapZone: UIView!
    private var bottomTapZone: UIView!

    var scrollView: UIScrollView? { webView?.scrollView }

    private let settings = AppSettings()

    init(article: Article, allowsFullscreen: Bool, onRefresh: (() -> Void)?, onRequestShowBars: @escaping () -> Void) {
        self.article = article
        self.allowsFullscreen = allowsFullscreen
        self.onRefresh = onRefresh
        self.onRequestShowBars = onRequestShowBars
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Compute the HTML this page would render; it is both the warmup match key and, on a miss,
        // what `render()` will load.
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize,
            summaryPending: summaryPending
        )

        isColdStartAnchorPage = StartupTrace.firstPageViewDidLoadOnce()
        if let warmed = ReaderWarmupStore.shared.take(identifier: article.identifier, html: html) {
            StartupTrace.warmupTakeOnce(hit: true)
            // Adopt the launch-warmed web view: its document is already parsed (and painted, if it
            // was parented off-screen). Detach from the warm host before re-parenting into this page.
            warmed.removeFromSuperview()
            webView = warmed
            loadedHTML = html                 // mark as already-loaded so `render()` no-ops
            adoptedWarmedView = true
        } else {
            StartupTrace.warmupTakeOnce(hit: false)
            webView = WKWebView(frame: view.bounds, configuration: ReaderWebView.makeConfiguration())
            adoptedWarmedView = false
        }
        // Each page registers its own (weakly held) link message handler on the shared controller.
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(self), name: ReaderWeb.linkClickedHandler
        )
        // Avoid the white/system flash and the lingering previous article: the container shows a
        // system background (adapts light/dark) while the web view paints, then we fade it in.
        view.backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.alpha = 0
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if onRefresh != nil {
            let refresh = UIRefreshControl()
            refresh.addTarget(self, action: #selector(handleRefresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }

        configureTapZones()
        // Re-render live (no app restart) when the reader's appearance settings change.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceDidChange),
            name: ArticleThemesManager.currentThemeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceDidChange),
            name: AppSettings.articleTextSizeDidChange, object: nil
        )
        if adoptedWarmedView {
            // The document is already loaded; just reveal it. If the load already finished (no
            // delegate was attached during warmup, so `didFinish` won't fire again), fade in now;
            // otherwise the navigation delegate fades it in on `didFinish`.
            if !webView.isLoading {
                if isColdStartAnchorPage { Self.markAnchorVisibleOnce(adopted: adoptedWarmedView) }
                UIView.animate(withDuration: CrossFade.duration) { self.webView.alpha = 1 }
            }
        } else {
            render()
        }
    }

    func reload() { render() }

    @objc private func appearanceDidChange() { render() }

    private func render(force: Bool = false) {
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize,
            summaryPending: summaryPending
        )
        guard force || html != loadedHTML else { return }
        webView.alpha = 0
        loadedHTML = html
        // Load against the bundle directory (like NetNewsWire), not a fake web origin. The article's
        // own `<base href>` resolves relative links to the real site; the injected click handler
        // (see ReaderWeb.linkInterceptionScript) then routes tapped links to the in-app browser.
        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
    }

    @objc private func handleRefresh(_ control: UIRefreshControl) {
        onRefresh?()
        control.endRefreshing()
    }

    // MARK: - Full-screen tap zones

    func hideBarsTapZonesActive(_ active: Bool) {
        topTapZone?.isHidden = !active
        bottomTapZone?.isHidden = !active
    }

    private func configureTapZones() {
        topTapZone = makeTapZone()
        bottomTapZone = makeTapZone()
        NSLayoutConstraint.activate([
            topTapZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topTapZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topTapZone.topAnchor.constraint(equalTo: view.topAnchor),
            topTapZone.heightAnchor.constraint(equalToConstant: 44),
            bottomTapZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomTapZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomTapZone.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomTapZone.heightAnchor.constraint(equalToConstant: 44)
        ])
        topTapZone.isHidden = true
        bottomTapZone.isHidden = true
    }

    private func makeTapZone() -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapZoneTapped)))
        view.addSubview(v)
        return v
    }

    @objc private func tapZoneTapped() { onRequestShowBars() }

    // MARK: - Links → in-app browser

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.alpha < 1 else { return }
        if isColdStartAnchorPage { Self.markAnchorVisibleOnce(adopted: adoptedWarmedView) }
        UIView.animate(withDuration: CrossFade.duration) { webView.alpha = 1 }
    }

    /// One-shot cold-start marker: logs when the very first reader page is revealed to the user
    /// (the anchor article), distinguishing a warmup adoption from a cold render.
    private static var didMarkAnchorVisible = false
    static func markAnchorVisibleOnce(adopted: Bool) {
        guard !didMarkAnchorVisible else { return }
        didMarkAnchorVisible = true
        StartupTrace.event(adopted ? "anchorVisible(adopted)" : "anchorVisible(rendered)")
    }

    /// The shared Web Content process was terminated — almost always jetsam while the app sat
    /// suspended in the background (the reader prewarms several web views into one shared process
    /// pool, making that process a heavy reclaim target). WebKit does not reload automatically, so
    /// without this the page comes back blank — and a plain `render()` no-ops because the HTML is
    /// unchanged, which is why only killing and relaunching the app used to recover. Force a
    /// re-render to repopulate the now-empty web view.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        render(force: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        // Only a link the user tapped (`.linkActivated`) leaves the reader; the article load,
        // image-scheme requests and embeds are `.other` and load in place. See ReaderLinkPolicy.
        if ReaderLinkPolicy.opensExternally(url: url, navigationType: navigationAction.navigationType) {
            decisionHandler(.cancel)
            openExternally(url)
            return
        }
        decisionHandler(.allow)
    }

    // Primary link path: the injected click handler posts the resolved absolute href here.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ReaderWeb.linkClickedHandler,
              let href = message.body as? String,
              let url = ReaderLinkPolicy.externalURL(fromClickedHref: href) else { return }
        openExternally(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    private func openExternally(_ url: URL) {
        // This view controller is a page inside a UIPageViewController; presenting from it directly
        // can silently fail, so present from the top-most controller in the window.
        ReaderLinkPolicy.openExternally(url, useSystemBrowser: settings.useSystemBrowser) { [weak self] in
            self?.topmostPresenter ?? self
        }
    }

    /// The deepest currently-presented controller reachable from this scene's root, or nil if
    /// the view is not yet in a window.
    private var topmostPresenter: UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// Forwards script messages to a weakly-held delegate. `WKUserContentController` retains its message
/// handlers strongly; registering the view controller directly would create a retain cycle
/// (controller → webView → configuration → userContentController → controller).
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}
