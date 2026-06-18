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

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ReaderWeb.imageScheme)
        // Intercept link taps at the DOM level rather than via the navigation delegate: WebKit does
        // not reliably classify tapped links inside a `loadHTMLString`-rendered document as
        // `.linkActivated`, so `decidePolicyFor` would let them load in place. The injected script
        // posts the browser-resolved absolute href here (the delegate stays as defense-in-depth).
        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(self), name: ReaderWeb.linkClickedHandler)
        controller.addUserScript(WKUserScript(
            source: ReaderWeb.linkInterceptionScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        config.userContentController = controller
        webView = WKWebView(frame: view.bounds, configuration: config)
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
        render()
    }

    func reload() { render() }

    @objc private func appearanceDidChange() { render() }

    private func render() {
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize
        )
        guard html != loadedHTML else { return }
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url); return
        }
        if settings.useSystemBrowser {
            UIApplication.shared.open(url)
        } else {
            // This view controller is a page inside a UIPageViewController; presenting from it
            // directly can silently fail, so present from the top-most controller in the window.
            let presenter = topmostPresenter ?? self
            presenter.present(SFSafariViewController(url: url), animated: true)
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
