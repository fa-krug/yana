import SwiftUI
import UIKit
import WebKit

/// Horizontal pager over the timeline. Each page is an `ArticleContentView` whose web view
/// owns vertical scrolling and pinch-to-zoom; articles slide edge-to-edge via a native
/// `UIPageViewController` (scroll transition style), mirroring NetNewsWire's reader. Only the
/// visible page and the transient neighbour are kept alive, so an endless timeline never
/// instantiates a web view per article.
struct ArticlePagerView: UIViewControllerRepresentable {
    let articles: [Article]
    @Binding var currentIndex: Int
    /// Forwarded to each page's web view for pull-to-refresh.
    var onRefresh: (() -> Void)?
    /// Real safe-area insets (including the navigation bar) captured by the reader before it
    /// draws the pager full-bleed, so each page can inset the article clear of the floating bars.
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    private var clampedIndex: Int {
        min(max(currentIndex, 0), max(0, articles.count - 1))
    }

    func makeUIViewController(context: Context) -> ArticlePagerController {
        let controller = ArticlePagerController()
        controller.onIndexChange = { currentIndex = $0 }
        controller.configure(articles: articles, index: clampedIndex, onRefresh: onRefresh, safeAreaInsets: safeAreaInsets)
        return controller
    }

    func updateUIViewController(_ controller: ArticlePagerController, context: Context) {
        controller.onIndexChange = { currentIndex = $0 }
        controller.update(articles: articles, index: clampedIndex, onRefresh: onRefresh, safeAreaInsets: safeAreaInsets)
    }
}

/// Hosts a native `UIPageViewController` (scroll transition style) that pages through the
/// timeline. The data source vends only the neighbour the user is sliding toward, so an
/// endless timeline keeps just the visible page (plus the transient neighbour) alive.
@MainActor
final class ArticlePagerController: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    var onIndexChange: ((Int) -> Void)?

    private let pageController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: nil // native default inter-page gap
    )

    private var articles: [Article] = []
    private var index = 0
    private var onRefresh: (() -> Void)?
    private var safeAreaInsets = EdgeInsets()
    /// True between `willTransitionTo` and `didFinishAnimating`, so SwiftUI-driven
    /// `update(...)` never reshuffles pages mid-swipe.
    private var isTransitioning = false

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
    }

    func configure(articles: [Article], index: Int, onRefresh: (() -> Void)?, safeAreaInsets: EdgeInsets) {
        self.articles = articles
        self.index = index
        self.onRefresh = onRefresh
        self.safeAreaInsets = safeAreaInsets
        loadViewIfNeeded()
        if let page = makePage(for: index) {
            pageController.setViewControllers([page], direction: .forward, animated: false)
            observeCurrentWebView()
            updatePagingForZoom()
        }
    }

    func update(articles: [Article], index: Int, onRefresh: (() -> Void)?, safeAreaInsets: EdgeInsets) {
        self.onRefresh = onRefresh
        self.articles = articles
        let insetsChanged = safeAreaInsets != self.safeAreaInsets
        self.safeAreaInsets = safeAreaInsets
        // Never reshuffle pages mid-swipe.
        guard !isTransitioning else { return }

        // Re-apply insets to the visible page on rotation / safe-area change (same article,
        // so this re-renders the inset without reloading the web document).
        if insetsChanged, let page = displayedPage {
            page.rootView = makeContentView(for: page.article)
        }

        let displayedID = displayedPage?.article.identifier
        let targetID = articles.indices.contains(index) ? articles[index].identifier : nil
        self.index = index
        guard displayedID != targetID, let page = makePage(for: index) else { return }
        // Programmatic move (restore anchor / clamp after a filter change): no animation.
        pageController.setViewControllers([page], direction: .forward, animated: false)
        observeCurrentWebView()
        updatePagingForZoom()
    }

    // MARK: - Pages

    private var displayedPage: ArticlePage? {
        pageController.viewControllers?.first as? ArticlePage
    }

    private func makePage(for index: Int) -> ArticlePage? {
        guard articles.indices.contains(index) else { return nil }
        let article = articles[index]
        return ArticlePage(article: article, contentView: makeContentView(for: article))
    }

    private func makeContentView(for article: Article) -> ArticleContentView {
        ArticleContentView(article: article, onRefresh: onRefresh, safeAreaInsets: safeAreaInsets, fullBleed: true)
    }

    private func displayedIndex(of page: ArticlePage) -> Int? {
        TimelinePageIndex.index(of: page.article.identifier, in: articles)
    }

    // MARK: - Zoom / wide-content paging lock

    /// The web scroll view currently observed for content-size (zoom) changes.
    private weak var observedScrollView: UIScrollView?

    /// Disables the pager's scroll while the current article's web view can scroll
    /// horizontally (zoomed in or content wider than the screen), so a horizontal drag
    /// scrolls the article instead of flipping the page. Re-enabled once it fits.
    private func updatePagingForZoom() {
        guard let scrollView = pagerScrollView else { return }
        scrollView.isScrollEnabled = !currentWebViewScrollsHorizontally
    }

    private var currentWebViewScrollsHorizontally: Bool {
        guard let root = displayedPage?.view,
              let scrollView = Self.webScrollView(in: root) else { return false }
        return scrollView.contentSize.width > scrollView.bounds.width + 1
    }

    /// The page controller's internal scroll view (scroll transition style). Found
    /// defensively so a future iOS change degrades to "always pages" rather than crashing.
    private var pagerScrollView: UIScrollView? {
        pageController.view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    /// Observe the current page's web scroll view so we re-evaluate when it loads or zooms.
    private func observeCurrentWebView() {
        if let old = observedScrollView {
            old.removeObserver(self, forKeyPath: "contentSize")
            observedScrollView = nil
        }
        guard let root = displayedPage?.view,
              let scrollView = Self.webScrollView(in: root) else { return }
        scrollView.addObserver(self, forKeyPath: "contentSize", options: [.new], context: nil)
        observedScrollView = scrollView
    }

    override nonisolated func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // KVO for a UIScrollView's contentSize is delivered on the main thread.
        MainActor.assumeIsolated { updatePagingForZoom() }
    }

    deinit {
        observedScrollView?.removeObserver(self, forKeyPath: "contentSize")
    }

    private static func webScrollView(in view: UIView) -> UIScrollView? {
        if let webView = view as? WKWebView { return webView.scrollView }
        for subview in view.subviews {
            if let found = webScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? ArticlePage,
              let i = displayedIndex(of: page), i > 0 else { return nil }
        return makePage(for: i - 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? ArticlePage,
              let i = displayedIndex(of: page), i < articles.count - 1 else { return nil }
        return makePage(for: i + 1)
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        isTransitioning = true
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        isTransitioning = false
        guard completed, let page = displayedPage, let i = displayedIndex(of: page) else { return }
        index = i
        onIndexChange?(i)
        observeCurrentWebView()
        updatePagingForZoom()
    }
}

/// Hosts an `ArticleContentView` and remembers which article it shows, so the pager can tell
/// whether the displayed article still matches the timeline after the list changes.
final class ArticlePage: UIHostingController<ArticleContentView> {
    let article: Article

    init(article: Article, contentView: ArticleContentView) {
        self.article = article
        super.init(rootView: contentView)
        view.backgroundColor = .systemBackground
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
