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

    /// Set by the pager on the page it is about to *display* so that page's first paint renders the
    /// body as plain text and upgrades to the selectable `UITextView` a runloop later (keeping the
    /// TextKit layout off the first-paint path). Consumed once by the first `makeRootView`; prewarmed
    /// neighbors leave it false so they render straight to `SelectableText`, laid out off-screen.
    var startsWithFastText = false

    /// A reading position handed to `restoreReadingOffset`, held until it has actually been
    /// applied. A freshly built page has no laid-out content yet, so the restore has to wait for
    /// `viewDidLayoutSubviews`.
    private var pendingReadingOffset: CGPoint?

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

    // MARK: - Reading position

    /// The body's scroll view — the outermost *scrollable* one inside the hosting controller,
    /// which is SwiftUI's `HostingScrollView` backing `ArticleBlockView`'s root `ScrollView`.
    ///
    /// The `isScrollEnabled` test is the load-bearing part, not a nicety: `SelectableText`'s
    /// `UITextView` is also a `UIScrollView` and sits deeper in the same tree with
    /// `isScrollEnabled == false` and `contentSize == bounds`. Its `contentOffset` accepts a write
    /// and reads back, but scrolls nothing and is discarded on the next text layout — so treating
    /// it as the reading position silently reports a value the reader never had.
    private var bodyScrollView: UIScrollView? {
        guard isViewLoaded, let root = host?.view else { return nil }
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? UIScrollView, scroll.isScrollEnabled { return scroll }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// How far into this article the user has read, or `nil` when there is nothing to measure —
    /// the body isn't laid out, or its backing was purged while the app was suspended.
    ///
    /// The `nil` is the point: answering `.zero` here is indistinguishable from a user who really
    /// is at the top of the article, so a save taken while the views are being torn down
    /// overwrites a good stored position with 0, and the next launch has nothing to restore.
    var readingOffset: CGPoint? {
        guard let scroll = bodyScrollView, scroll.contentSize.height > 0 else { return nil }
        return scroll.contentOffset
    }

    /// Whether a restore is still waiting for the body to grow enough to hold it. Test-facing.
    var hasPendingReadingOffset: Bool { pendingReadingOffset != nil }

    /// Put a reading position onto this page — the position the reader was at when the app was
    /// last backgrounded or left (`AppSettings.timelineAnchorReadingOffset`), applied on a cold
    /// launch and on the return from a background trip.
    ///
    /// Applied immediately if the body is already laid out, otherwise retried from
    /// `viewDidLayoutSubviews` until it lands (a page built from scratch has no content size yet).
    func restoreReadingOffset(_ offset: CGPoint) {
        pendingReadingOffset = offset
        applyPendingReadingOffset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPendingReadingOffset()
    }

    /// Applies `pendingReadingOffset`, and keeps holding it until the body has actually grown
    /// enough to satisfy it.
    ///
    /// **Consuming it on the first layout pass is wrong**, which is what this used to do: a page
    /// is laid out well before it is finished growing — the first paint renders plain text and
    /// upgrades to `SelectableText` a runloop later (`startsWithFastText`), and a lead image
    /// resolves later still (`ArticleBlockView`'s reveal gate). Clamping to whatever short body
    /// existed at that instant and then throwing the target away leaves the reader short of where
    /// it was, with nothing left to correct it. So the clamp is applied every pass as a best
    /// effort, but the target is only released once the body can hold it exactly.
    ///
    /// The user always wins: once they touch the scroll view, the pending restore is abandoned
    /// rather than dragging them back.
    private func applyPendingReadingOffset() {
        guard let wanted = pendingReadingOffset, let scroll = bodyScrollView else { return }
        guard !scroll.isDragging, !scroll.isDecelerating else { pendingReadingOffset = nil; return }
        let inset = scroll.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        // Nothing scrollable yet: the body hasn't laid out at all. Wait for the next pass.
        guard maxY > minY else { return }
        let clamped = CGPoint(x: scroll.contentOffset.x, y: min(max(wanted.y, minY), maxY))
        if clamped.y >= wanted.y { pendingReadingOffset = nil }
        guard scroll.contentOffset != clamped else { return }
        scroll.setContentOffset(clamped, animated: false)
    }

    @objc private func rebuild() { host?.rootView = makeRootView() }

    private func makeRootView() -> ArticleBlockView {
        // Consume-once: only the very first render (the page the pager is about to show) defers the
        // selectable upgrade. Later rebuilds (font/size change, reload) go straight to selectable.
        let deferSelectable = startsWithFastText
        startsWithFastText = false
        return ArticleBlockView(
            article: ReaderArticle(article),
            textSize: settings.articleTextSize,
            font: settings.articleFont,
            summaryPending: summaryPending,
            deferSelectableText: deferSelectable,
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
