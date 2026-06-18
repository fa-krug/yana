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
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: ArticleThemesManager.currentThemeDidChange, object: nil
        )
        render()
    }

    func reload() { render() }

    @objc private func themeDidChange() { render() }

    private func render() {
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize
        )
        guard html != loadedHTML else { return }
        loadedHTML = html
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

    // MARK: - Links → native browser

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            openExternally(url)
            return
        }
        decisionHandler(.allow)
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
            present(SFSafariViewController(url: url), animated: true)
        }
    }
}
