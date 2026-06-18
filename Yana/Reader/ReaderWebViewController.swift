import UIKit
import WebKit
import SafariServices

/// Hosts one article's `WKWebView`, pinned full-screen under the (opaque) bars so WKWebView's
/// automatic content-inset adjustment keeps the article clear of them. Ported/adapted from
/// NetNewsWire's WebViewController, trimmed of Account/extractor/search.
@MainActor
final class ReaderWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    let article: Article
    private let allowsFullscreen: Bool
    private let onRefresh: (() -> Void)?
    private let onRequestShowBars: () -> Void

    private var webView: WKWebView!
    private var loadedHTML: String?
    /// Set immediately before each programmatic `loadHTMLString`; the next main-frame navigation is
    /// that load (loaded in place). Every other main-frame navigation is a followed link.
    private var expectingArticleLoad = false

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
        expectingArticleLoad = true
        webView.loadHTMLString(html, baseURL: URL(string: ReaderWeb.baseOrigin))
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
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        // While the reader's own programmatic article load is still in flight, every main-frame
        // navigation is that load. The flag is cleared in `didCommit` (not here) because WebKit does
        // not reliably route a `loadHTMLString` load through this method — if we consumed the flag
        // here, the first tapped link would be mistaken for the article load and open in place.
        let isExpectedArticleLoad = expectingArticleLoad && isMainFrame
        // Our own rendered article and `yana-img://` image requests load in place; any followed
        // link is cancelled and opened in the same browser as the Open-in-Browser button.
        if ReaderLinkPolicy.opensExternally(
            url: url, navigationType: navigationAction.navigationType,
            targetIsMainFrame: isMainFrame, isExpectedArticleLoad: isExpectedArticleLoad) {
            decisionHandler(.cancel)
            openExternally(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The article load (or a live re-render) has committed; any later main-frame navigation is
        // a followed link that must leave the reader.
        expectingArticleLoad = false
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
