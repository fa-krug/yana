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
    private var articles: [ArticleSummary] = []
    /// Resolves a summary to its full `Article` (with body blocks) on demand, set by the host.
    var resolveArticle: ((ArticleSummary) -> Article?)?
    private var index = 0
    private var isTransitioning = false

    /// Identifiers of the pages adjacent to the displayed article the last time the pager's
    /// neighbors were wired up. `UIPageViewController` caches its before/after pages and only
    /// re-queries the data source on a `setViewControllers` call or a completed swipe — so a
    /// timeline mutation that changes these (a refresh appending new articles next to the current
    /// page) needs a forced re-query. We compare against this snapshot to decide when one is due.
    private var wiredNeighborIDs: (before: String?, after: String?) = (nil, nil)

    /// Reader prewarm/cache tuning. Constants so they can be profiled and dialed on-device.
    /// Each prewarmed neighbor builds a native hosting page off-screen and each cached page keeps
    /// one alive. The radius is kept small (warm 2 ahead + 2 behind) so a normal swipe lands on an
    /// already-built page without paying to build up to 2*radius views on every transition; the
    /// capacity holds that ±radius window plus a little recent history, then evicts to bound memory.
    private static let prewarmRadius = 2
    private static let pageCacheCapacity = 11

    /// Reused page controllers keyed by article identifier; revisiting a recent article is then
    /// instant (no re-render). LRU eviction bounds the number of live hosting controllers.
    private let pageCache = LRUCache<String, ReaderBlockViewController>(capacity: pageCacheCapacity)

    /// Last observed travel direction, used to bias prewarming toward where the user is going.
    private var lastDirection: PrewarmPlan.Direction = .none

    private let settings = AppSettings()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var articleListItem: UIBarButtonItem!
    private var filterItem: UIBarButtonItem!
    private var indicatorItem: UIBarButtonItem!
    private var starItem: UIBarButtonItem!
    private var shareItem: UIBarButtonItem!
    private var speakItem: UIBarButtonItem!
    private var menuItem: UIBarButtonItem!

    /// Reads the current article aloud; lives at the pager level so one synthesizer survives swipes.
    private let speech = ReaderSpeechController()

    private var isFullscreenAvailable: Bool { traitCollection.userInterfaceIdiom == .phone }
    private var displayedPage: ReaderBlockViewController? {
        pageController.viewControllers?.first as? ReaderBlockViewController
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
        displayedPage?.reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Don't keep reading after the reader is left.
        speech.stop()
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
        navigationItem.leftBarButtonItems = [articleListItem]

        starItem = UIBarButtonItem(image: UIImage(systemName: "star"), style: .plain, target: self, action: #selector(toggleStar))

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
        // rightBarButtonItems is ordered edge-inward: [menu, filter, star] puts the overflow menu at
        // the screen edge, then the filter, then the star (on-screen L→R: star, filter, menu).
        navigationItem.rightBarButtonItems = [menuItem, filterItem, starItem]
    }

    private func configureToolbar() {
        shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareArticle))
        let browser = UIBarButtonItem(image: UIImage(systemName: "safari"), style: .plain, target: self, action: #selector(openInBrowser))
        speakItem = UIBarButtonItem(image: UIImage(systemName: "play.circle"), style: .plain, target: self, action: #selector(toggleSpeech))
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        // Read-aloud + Share + Open-in-Browser grouped together at the right edge, with the
        // read-aloud (play/pause) button left-most of the group.
        toolbarItems = [flex(), speakItem, shareItem, browser]
        updateSpeakItem()
        // Reflect synthesizer state transitions (pause, finish) back onto the toolbar button.
        speech.onStateChange = { [weak self] in self?.updateSpeakItem() }
    }

    private func updateSpeakItem() {
        let speaking = speech.state == .speaking
        speakItem.image = UIImage(systemName: speaking ? "pause.circle" : "play.circle")
        speakItem.accessibilityLabel = speaking
            ? String(localized: "Pause reading")
            : String(localized: "Read article aloud")
    }

    func setRefreshing(_ isRefreshing: Bool) {
        if isRefreshing { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        let items: [UIBarButtonItem] = isRefreshing ? [articleListItem, indicatorItem] : [articleListItem]
        guard navigationItem.leftBarButtonItems?.count != items.count else { return }
        navigationItem.leftBarButtonItems = items
        // Re-assert the right group so iOS 26's nav bar re-runs its overflow pass. The spinner is a
        // custom-view bar item, which the bar cannot move into its automatic "•••" overflow; under a
        // width-constrained layout it overflows the *standard* buttons instead, and that collapse
        // sticks even after the spinner is gone unless a fresh layout is forced. Reassigning the
        // (unchanged) right items is that nudge, so star + filter + menu reappear when refresh ends.
        navigationItem.rightBarButtonItems = [menuItem, filterItem, starItem]
    }

    func setFilterActive(_ active: Bool) {
        filterItem.image = UIImage(systemName: active
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle")
    }

    private func updateStarItem() {
        guard let article = currentArticle() else { return }
        starItem.image = UIImage(systemName: article.isStarred ? "star.fill" : "star")
        starItem.accessibilityLabel = article.isStarred
            ? String(localized: "Unstar article") : String(localized: "Star article")
    }

    // MARK: - Data

    func configure(articles: [ArticleSummary], index: Int) {
        self.articles = articles
        self.index = clamp(index)
        loadViewIfNeeded()
        if let page = makePage(for: self.index) {
            pageController.setViewControllers([page], direction: .forward, animated: false)
            recordWiredNeighbors()
        }
        updateStarItem()
        // Defer neighbor prewarming off the launch path. `configure` runs synchronously inside
        // `makeUIViewController`, before the first frame is presented; prewarming here would build
        // and render up to 2*prewarmRadius extra WKWebViews before the user sees the visible page.
        // Hopping to the next runloop lets the on-screen article render and present first, then the
        // neighbors warm in the background — same indices, just after first paint.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prewarmNeighbors(around: self.index)
        }
    }

    func update(articles: [ArticleSummary], index: Int) {
        self.articles = articles
        guard !isTransitioning else { return }
        let target = clamp(index)
        let displayedID = displayedPage?.article.identifier
        let targetID = articles.indices.contains(target) ? articles[target].identifier : nil
        self.index = target

        if displayedID == targetID {
            // The displayed article is unchanged, but the timeline may have mutated around it: a
            // refresh appends newly fetched articles next to the current page (when parked on the
            // newest article they land right after it). `UIPageViewController` cached its adjacent
            // pages when this article was set and won't re-query until the displayed page changes,
            // so those new neighbors stay unswipeable — the user is stuck until they navigate away
            // and back. Re-assert the current page when its neighbors changed to force the re-query.
            if let displayed = displayedPage, neighborIDs(of: displayedID) != wiredNeighborIDs {
                pageController.setViewControllers([displayed], direction: .forward, animated: false)
                recordWiredNeighbors()
            }
            updateStarItem()
            return
        }

        guard let page = makePage(for: target) else { updateStarItem(); return }
        speech.stop()
        pageController.setViewControllers([page], direction: .forward, animated: false)
        recordWiredNeighbors()
        updateStarItem()
    }

    /// Identifiers immediately before/after the page for `identifier` in the current timeline.
    private func neighborIDs(of identifier: String?) -> (before: String?, after: String?) {
        guard let i = TimelinePageIndex.index(of: identifier, in: articles) else { return (nil, nil) }
        let before = i > 0 ? articles[i - 1].identifier : nil
        let after = i < articles.count - 1 ? articles[i + 1].identifier : nil
        return (before, after)
    }

    /// Snapshot the displayed article's neighbors after the pager has (re)wired its adjacent pages.
    private func recordWiredNeighbors() {
        wiredNeighborIDs = neighborIDs(of: displayedPage?.article.identifier)
    }

    private func clamp(_ i: Int) -> Int { min(max(i, 0), max(0, articles.count - 1)) }

    private func currentArticle() -> Article? {
        displayedPage?.article
    }

    private func makePage(for index: Int) -> ReaderBlockViewController? {
        guard articles.indices.contains(index) else { return nil }
        let summary = articles[index]
        if let cached = pageCache.value(for: summary.identifier) { return cached }
        guard let article = resolveArticle?(summary) else { return nil }
        let vc = ReaderBlockViewController(
            article: article,
            allowsFullscreen: isFullscreenAvailable,
            onRefresh: onRefresh,
            onRequestShowBars: { [weak self] in self?.applyFullscreen(false, animated: true) }
        )
        vc.hideBarsTapZonesActive(settings.articleFullscreenEnabled && isFullscreenAvailable)
        pageCache.insert(vc, for: summary.identifier)
        return vc
    }

    /// Instantiate the neighbors around `index`, biased toward the last travel direction, so a
    /// burst of swipes lands on already-built pages.
    private func prewarmNeighbors(around index: Int) {
        let targets = PrewarmPlan.indices(
            current: index, count: articles.count,
            radius: Self.prewarmRadius, direction: lastDirection
        )
        for i in targets {
            let vc = makePage(for: i)         // inserts into cache
            vc?.loadViewIfNeeded()            // force viewDidLoad → build the hosting view off-screen
        }
    }

    // MARK: - Actions

    @objc private func showFilter() { onShowFilter?() }
    @objc private func showArticleList() { onShowArticleList?() }
    @objc private func showSettings() { onShowSettings?() }

    @objc private func toggleStar() {
        guard let article = currentArticle() else { return }
        onToggleStar?(article)
        updateStarItem()
    }

    /// Start reading the current article when idle; otherwise pause/resume the in-flight reading.
    @objc private func toggleSpeech() {
        if speech.state == .idle {
            guard let article = currentArticle() else { return }
            speech.speak(article)
        } else {
            speech.togglePauseResume()
        }
    }

    private func buildMenuActions() -> [UIMenuElement] {
        guard let article = currentArticle() else { return [] }
        let config = ReaderMenuBuilder.config(
            hasURL: !article.url.isEmpty, aiReady: aiReady
        )
        var actions: [UIMenuElement] = []

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
        displayedPage?.reload()
    }

    /// Toggle the pending-summary placeholder on the visible page (the only one being summarized).
    func setSummarizing(_ summarizing: Bool) {
        displayedPage?.summaryPending = summarizing
    }

    @objc private func shareArticle() {
        guard let article = currentArticle(), let url = URL(string: article.url) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let presenter = topmostPresenter ?? self
        activity.popoverPresentationController?.barButtonItem = shareItem
        presenter.present(activity, animated: true)
    }

    /// The deepest currently-presented controller reachable from this scene's root, or nil if
    /// the view is not yet in a window. Mirrors ReaderBlockViewController.topmostPresenter.
    private var topmostPresenter: UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    @objc private func openInBrowser() {
        guard let article = currentArticle(), let url = URL(string: article.url),
              url.scheme == "http" || url.scheme == "https" else { return }
        // Match in-article link taps: try the corresponding native app (universal link) first, then
        // fall back to the in-app Safari view / system browser. See ReaderLinkPolicy.openExternally.
        ReaderLinkPolicy.openExternally(url, useSystemBrowser: settings.useSystemBrowser) { [weak self] in
            self?.topmostPresenter ?? self
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
        // Apply to every cached page, not just the visible one: neighbors are prewarmed ahead of the
        // swipe and bake in the tap-zone state from when they were created. If a neighbor was warmed
        // before fullscreen was toggled, it would otherwise keep stale (hidden) tap zones, so after
        // swiping to it the tap-to-exit area beside the notch is gone.
        for page in pageCache.values { page.hideBarsTapZonesActive(hidden) }
        setNeedsStatusBarAppearanceUpdate()
    }

    override var prefersStatusBarHidden: Bool {
        settings.articleFullscreenEnabled && isFullscreenAvailable
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ReaderBlockViewController,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles), i > 0 else { return nil }
        return makePage(for: i - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ReaderBlockViewController,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles), i < articles.count - 1 else { return nil }
        return makePage(for: i + 1)
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        if let next = pendingViewControllers.first as? ReaderBlockViewController,
           let target = TimelinePageIndex.index(of: next.article.identifier, in: articles) {
            lastDirection = target > index ? .forward : .backward
            prewarmNeighbors(around: target)   // warm mid-swipe, not only after it finishes
        }
        isTransitioning = true
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        isTransitioning = false
        guard completed, let vc = displayedPage,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles) else { return }
        // Reading aloud is tied to the article that was visible when it started; a new page means a
        // new article, so stop rather than keep narrating the one the user swiped away from.
        speech.stop()
        index = i
        recordWiredNeighbors()
        updateStarItem()
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
