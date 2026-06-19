import UIKit
import SafariServices

/// Pages through the timeline with native opaque nav bar + toolbar and NNW-style tap-to-hide
/// full-screen. Adapted from NetNewsWire's ArticleViewController (no read state / extractor / search).
@MainActor
final class ReaderArticleViewController: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    var onIndexChange: ((Int) -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowArticleList: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?
    var onRefresh: (() -> Void)?
    var onForceUpdateArticle: ((Article) -> Void)?
    var onCopyLink: ((Article) -> Void)?
    var onSummarize: ((Article) -> Void)?
    /// Whether AI is configured/available; gates the Summarize menu item. Set by the host.
    var aiReady = false
    /// True while an on-demand summary is in flight; disables the Summarize menu item.
    var isSummarizing = false

    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private var articles: [Article] = []
    private var index = 0
    private var isTransitioning = false

    /// Reader prewarm/cache tuning. Constants so they can be profiled and dialed on-device.
    /// Radius covers a 5-swipe burst in one direction; capacity holds ±radius on both sides
    /// plus a little recent history, bounding live WKWebViews.
    private static let prewarmRadius = 5
    private static let pageCacheCapacity = 25

    /// Reused page controllers keyed by article identifier; revisiting a recent article is then
    /// instant (no re-render). LRU eviction tears down off-window web views to bound memory.
    private let pageCache = LRUCache<String, ReaderWebViewController>(capacity: pageCacheCapacity)

    /// Last observed travel direction, used to bias prewarming toward where the user is going.
    private var lastDirection: PrewarmPlan.Direction = .none

    private let settings = AppSettings()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let progressLabel = UILabel()
    private var progressItem: UIBarButtonItem!
    private var articleListItem: UIBarButtonItem!
    private var filterItem: UIBarButtonItem!
    private var indicatorItem: UIBarButtonItem!
    private var shareItem: UIBarButtonItem!
    private var menuItem: UIBarButtonItem!

    private var isFullscreenAvailable: Bool { traitCollection.userInterfaceIdiom == .phone }
    private var displayedWebVC: ReaderWebViewController? {
        pageController.viewControllers?.first as? ReaderWebViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        configureNavigationItems()
        configureToolbar()

        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )

        // Tap the nav bar to hide bars (NNW behavior).
        let tapZone = UIView()
        tapZone.translatesAutoresizingMaskIntoConstraints = false
        tapZone.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleFullscreenFromNavBar)))
        NSLayoutConstraint.activate([
            tapZone.widthAnchor.constraint(equalToConstant: 150),
            tapZone.heightAnchor.constraint(equalToConstant: 44)
        ])
        navigationItem.titleView = tapZone
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
        applyFullscreen(settings.articleFullscreenEnabled && isFullscreenAvailable, animated: false)
        displayedWebVC?.reload()
    }

    // MARK: - Chrome

    private func configureNavigationItems() {
        articleListItem = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            style: .plain, target: self, action: #selector(showArticleList)
        )
        articleListItem.accessibilityLabel = String(localized: "Article list")

        filterItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(showFilter)
        )
        filterItem.accessibilityLabel = String(localized: "Filter articles")
        // The loading indicator only joins the left group while a refresh runs (see
        // setRefreshing). A stopped indicator's bar-button item still reserves width, so it is
        // added/removed rather than left in place hidden.
        indicatorItem = UIBarButtonItem(customView: activityIndicator)
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = .secondaryLabel
        progressItem = UIBarButtonItem(customView: progressLabel)
        navigationItem.leftBarButtonItems = [articleListItem]

        // Overflow menu, rebuilt each time it opens so conditional items track the current
        // article + AI state. UIDeferredMenuElement.uncached re-invokes the provider per present.
        menuItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.buildMenuActions() ?? [])
                }
            ])
        )
        menuItem.accessibilityLabel = String(localized: "More actions")
        // rightBarButtonItems is ordered edge-inward: [menu, filter] puts the overflow menu at the
        // screen edge, then the filter (on-screen L→R: filter, menu). Starring lives in the overflow
        // menu rather than its own bar button: a fourth right-side item overflows the bar on
        // width-constrained displays (e.g. Display Zoom), and iOS 26 then collapses every button into
        // an automatic "•••" menu that sticks. Two right items leave headroom for the refresh spinner.
        navigationItem.rightBarButtonItems = [menuItem, filterItem]
    }

    private func configureToolbar() {
        shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareArticle))
        let browser = UIBarButtonItem(image: UIImage(systemName: "safari"), style: .plain, target: self, action: #selector(openInBrowser))
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        // Share + Open-in-Browser grouped together at the right edge.
        toolbarItems = [flex(), shareItem, browser]
    }

    /// Show "Updating N of M…" during a counted multi-feed run; pass nil to clear. The indeterminate
    /// spinner (setRefreshing) still drives the activity indicator itself.
    func setUpdateProgress(_ progress: (completed: Int, total: Int)?) {
        guard let progress, progress.total > 1 else {
            if navigationItem.leftBarButtonItems?.contains(progressItem) == true {
                setRefreshing(activityIndicator.isAnimating) // rebuild left items without progress
            }
            return
        }
        progressLabel.text = String(localized: "Updating \(progress.completed) of \(progress.total)…")
        progressLabel.sizeToFit()
        let items: [UIBarButtonItem] = [articleListItem, indicatorItem, progressItem]
        if navigationItem.leftBarButtonItems != items {
            navigationItem.leftBarButtonItems = items
        }
    }

    func setRefreshing(_ isRefreshing: Bool) {
        if isRefreshing { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        let items: [UIBarButtonItem] = isRefreshing ? [articleListItem, indicatorItem] : [articleListItem]
        if navigationItem.leftBarButtonItems?.count != items.count {
            navigationItem.leftBarButtonItems = items
        }
    }

    func setFilterActive(_ active: Bool) {
        filterItem.image = UIImage(systemName: active
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle")
    }

    // MARK: - Data

    func configure(articles: [Article], index: Int) {
        self.articles = articles
        self.index = clamp(index)
        loadViewIfNeeded()
        if let page = makePage(for: self.index) {
            pageController.setViewControllers([page], direction: .forward, animated: false)
        }
        prewarmNeighbors(around: self.index)
    }

    func update(articles: [Article], index: Int) {
        self.articles = articles
        guard !isTransitioning else { return }
        let target = clamp(index)
        let displayedID = displayedWebVC?.article.identifier
        let targetID = articles.indices.contains(target) ? articles[target].identifier : nil
        self.index = target
        guard displayedID != targetID, let page = makePage(for: target) else { return }
        pageController.setViewControllers([page], direction: .forward, animated: false)
    }

    private func clamp(_ i: Int) -> Int { min(max(i, 0), max(0, articles.count - 1)) }

    private func currentArticle() -> Article? {
        guard articles.indices.contains(index) else { return nil }
        return articles[index]
    }

    private func makePage(for index: Int) -> ReaderWebViewController? {
        guard articles.indices.contains(index) else { return nil }
        let article = articles[index]
        if let cached = pageCache.value(for: article.identifier) { return cached }
        let vc = ReaderWebViewController(
            article: article,
            allowsFullscreen: isFullscreenAvailable,
            onRefresh: onRefresh,
            onRequestShowBars: { [weak self] in self?.applyFullscreen(false, animated: true) }
        )
        vc.hideBarsTapZonesActive(settings.articleFullscreenEnabled && isFullscreenAvailable)
        pageCache.insert(vc, for: article.identifier)
        return vc
    }

    /// Instantiate (and thus begin loading) the neighbors around `index`, biased toward the last
    /// travel direction, so a burst of swipes lands on already-rendered HTML.
    private func prewarmNeighbors(around index: Int) {
        let targets = PrewarmPlan.indices(
            current: index, count: articles.count,
            radius: Self.prewarmRadius, direction: lastDirection
        )
        for i in targets {
            let vc = makePage(for: i)         // inserts into cache + triggers loadHTMLString
            vc?.loadViewIfNeeded()            // force viewDidLoad → render() now, off-screen
        }
    }

    // MARK: - Actions

    @objc private func showFilter() { onShowFilter?() }
    @objc private func showArticleList() { onShowArticleList?() }
    @objc private func showSettings() { onShowSettings?() }

    private func buildMenuActions() -> [UIMenuElement] {
        guard let article = currentArticle() else { return [] }
        let config = ReaderMenuBuilder.config(
            hasURL: !article.url.isEmpty, aiReady: aiReady
        )
        var actions: [UIMenuElement] = []

        let isStarred = article.isStarred
        actions.append(UIAction(
            title: isStarred ? String(localized: "Unstar") : String(localized: "Star"),
            image: UIImage(systemName: isStarred ? "star.slash" : "star")
        ) { [weak self] _ in self?.onToggleStar?(article) })

        actions.append(UIAction(
            title: String(localized: "Reload"),
            image: UIImage(systemName: "arrow.trianglehead.2.clockwise")
        ) { [weak self] _ in self?.onForceUpdateArticle?(article) })

        if config.showCopyLink {
            actions.append(UIAction(
                title: String(localized: "Copy link"),
                image: UIImage(systemName: "link")
            ) { [weak self] _ in self?.onCopyLink?(article) })
        }

        if config.showSummarize {
            let summarize = UIAction(
                title: String(localized: "Summarize"),
                image: UIImage(systemName: "sparkles")
            ) { [weak self] _ in self?.onSummarize?(article) }
            if isSummarizing { summarize.attributes = .disabled }
            actions.append(summarize)
        }

        let settings = UIAction(
            title: String(localized: "Settings"),
            image: UIImage(systemName: "gearshape")
        ) { [weak self] _ in self?.onShowSettings?() }
        actions.append(UIMenu(title: "", options: .displayInline, children: [settings]))

        return actions
    }

    func reloadCurrentPage() {
        displayedWebVC?.reload()
    }

    /// Toggle the pending-summary placeholder on the visible page (the only one being summarized).
    func setSummarizing(_ summarizing: Bool) {
        displayedWebVC?.summaryPending = summarizing
    }

    @objc private func shareArticle() {
        guard let article = currentArticle(), let url = URL(string: article.url) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let presenter = topmostPresenter ?? self
        activity.popoverPresentationController?.barButtonItem = shareItem
        presenter.present(activity, animated: true)
    }

    /// The deepest currently-presented controller reachable from this scene's root, or nil if
    /// the view is not yet in a window. Mirrors ReaderWebViewController.topmostPresenter.
    private var topmostPresenter: UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    @objc private func openInBrowser() {
        guard let article = currentArticle(), let url = URL(string: article.url),
              url.scheme == "http" || url.scheme == "https" else { return }
        if settings.useSystemBrowser {
            UIApplication.shared.open(url)
        } else {
            present(SFSafariViewController(url: url), animated: true)
        }
    }

    // MARK: - Full-screen

    @objc private func toggleFullscreenFromNavBar() {
        guard isFullscreenAvailable else { return }
        applyFullscreen(!settings.articleFullscreenEnabled, animated: true)
    }

    private func applyFullscreen(_ hidden: Bool, animated: Bool) {
        settings.articleFullscreenEnabled = hidden
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        navigationController?.setToolbarHidden(hidden, animated: animated)
        displayedWebVC?.hideBarsTapZonesActive(hidden)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var prefersStatusBarHidden: Bool {
        settings.articleFullscreenEnabled && isFullscreenAvailable
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ReaderWebViewController,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles), i > 0 else { return nil }
        return makePage(for: i - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ReaderWebViewController,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles), i < articles.count - 1 else { return nil }
        return makePage(for: i + 1)
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        if let next = pendingViewControllers.first as? ReaderWebViewController,
           let target = TimelinePageIndex.index(of: next.article.identifier, in: articles) {
            lastDirection = target > index ? .forward : .backward
            prewarmNeighbors(around: target)   // warm mid-swipe, not only after it finishes
        }
        isTransitioning = true
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        isTransitioning = false
        guard completed, let vc = displayedWebVC,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles) else { return }
        index = i
        onIndexChange?(i)
        prewarmNeighbors(around: i)
    }

    // MARK: - Memory

    @objc private func handleMemoryWarning() {
        // Keep only the live ±1 window so the current page and its immediate neighbors survive.
        let live = PrewarmPlan.indices(current: index, count: articles.count, radius: 1, direction: .none) + [index]
        let keep = Set(live.filter { articles.indices.contains($0) }.map { articles[$0].identifier })
        _ = pageCache.trim(toKeep: keep)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
