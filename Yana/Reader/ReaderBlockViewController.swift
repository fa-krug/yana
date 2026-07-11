import SwiftUI
import UIKit

/// Hosts one article's native `ArticleBlockView` (a `UIHostingController`) as a page inside the
/// reader's `UIPageViewController`. Replaces the former `WKWebView`-backed `ReaderWebViewController`:
/// no WebView, no warmup/pool, no themed HTML — the body is decoded from `[Block]` and rendered in
/// SwiftUI. Keeps the page surface the pager relies on: `article`, `reload()`, `summaryPending`,
/// `hideBarsTapZonesActive`, and the full-screen tap zones.
@MainActor
final class ReaderBlockViewController: UIViewController {

    let article: Article
    private let onRefresh: (() -> Void)?
    private let onRequestShowBars: () -> Void
    private let settings = AppSettings()

    private var host: UIHostingController<ArticleBlockView>!

    var summaryPending = false { didSet { if summaryPending != oldValue { rebuild() } } }

    private var topTapZone: UIView!
    private var bottomTapZone: UIView!
    /// Desired full-screen tap-zone state, remembered so it survives `viewDidLoad` (the pager may set
    /// it before the view exists, e.g. when prewarming a neighbor).
    private var tapZonesActive = false

    init(article: Article, allowsFullscreen: Bool, onRefresh: (() -> Void)?, onRequestShowBars: @escaping () -> Void) {
        self.article = article
        self.onRefresh = onRefresh
        self.onRequestShowBars = onRequestShowBars
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        host = UIHostingController(rootView: makeRootView())
        host.view.backgroundColor = .systemBackground
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // Re-render live (no app restart) when the article text size or font changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: AppSettings.articleTextSizeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: AppSettings.articleFontDidChange, object: nil
        )

        configureTapZones()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func reload() { rebuild() }

    @objc private func rebuild() { host?.rootView = makeRootView() }

    private func makeRootView() -> ArticleBlockView {
        ArticleBlockView(
            article: ReaderArticle(article),
            textSize: settings.articleTextSize,
            font: settings.articleFont,
            summaryPending: summaryPending,
            onOpenLink: { [weak self] url in self?.openExternally(url) },
            onPlayVideo: { [weak self] embed in self?.playVideo(embed) },
            onShowImage: { [weak self] ref in self?.showImage(ref) },
            onRefresh: onRefresh
        )
    }

    /// Open an image full-screen with pinch-to-zoom.
    private func showImage(_ ref: String) {
        let viewer = ReaderImageViewerViewController(ref: ref)
        (topmostPresenter ?? self).present(viewer, animated: true)
    }

    /// Play a video embed full-screen in-app. Falls back to opening the embed's URL externally when
    /// it isn't an inline-playable video (the card already routes those through `onOpenLink`, so this
    /// is just a safety net).
    private func playVideo(_ embed: Embed) {
        if let player = ReaderVideoPlayerViewController.make(for: embed) {
            (topmostPresenter ?? self).present(player, animated: true)
        } else if let url = URL(string: embed.externalURL) {
            openExternally(url)
        }
    }

    private func openExternally(_ url: URL) {
        ReaderLinkPolicy.openExternally(url, useSystemBrowser: settings.useSystemBrowser) { [weak self] in
            self?.topmostPresenter ?? self
        }
    }

    private var topmostPresenter: UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Full-screen tap zones

    func hideBarsTapZonesActive(_ active: Bool) {
        tapZonesActive = active
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
            bottomTapZone.heightAnchor.constraint(equalToConstant: 44),
        ])
        topTapZone.isHidden = !tapZonesActive
        bottomTapZone.isHidden = !tapZonesActive
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
}
