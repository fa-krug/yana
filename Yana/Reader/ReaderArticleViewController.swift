import UIKit
import SafariServices

/// Pages through the timeline with native opaque nav bar + toolbar and NNW-style tap-to-hide
/// full-screen. Adapted from NetNewsWire's ArticleViewController (no read state / extractor / search).
@MainActor
final class ReaderArticleViewController: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    var onIndexChange: ((Int) -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?
    var onRefresh: (() -> Void)?
    var onCopyLink: ((Article) -> Void)?
    var onSummarize: ((Article) -> Void)?
    var onGoToFeed: ((Feed) -> Void)?
    /// Whether AI is configured/available; gates the Summarize menu item. Set by the host.
    var aiReady = false
    /// True while an on-demand summary is in flight; disables the Summarize menu item.
    var isSummarizing = false

    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private var articles: [Article] = []
    private var index = 0
    private var isTransitioning = false

    private let settings = AppSettings()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var filterItem: UIBarButtonItem!
    private var indicatorItem: UIBarButtonItem!
    private var starItem: UIBarButtonItem!
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
        filterItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(showFilter)
        )
        filterItem.accessibilityLabel = String(localized: "Filter articles")
        // The loading indicator only joins the left group while a refresh runs (see
        // setRefreshing). A stopped indicator's bar-button item still reserves width, so it is
        // added/removed rather than left in place hidden.
        indicatorItem = UIBarButtonItem(customView: activityIndicator)
        navigationItem.leftBarButtonItems = [filterItem]

        let library = UIBarButtonItem(
            image: UIImage(systemName: "books.vertical"),
            style: .plain, target: self, action: #selector(showSettings)
        )
        library.accessibilityLabel = String(localized: "Library")
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
        // rightBarButtonItems is ordered edge-inward: [menu, library, star] puts the overflow
        // menu at the screen edge, then the library button, then the star.
        navigationItem.rightBarButtonItems = [menuItem, library, starItem]
    }

    private func configureToolbar() {
        shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareArticle))
        let browser = UIBarButtonItem(image: UIImage(systemName: "safari"), style: .plain, target: self, action: #selector(openInBrowser))
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        // Share + Open-in-Browser grouped together at the right edge.
        toolbarItems = [flex(), shareItem, browser]
    }

    func setRefreshing(_ isRefreshing: Bool) {
        if isRefreshing { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        let items: [UIBarButtonItem] = isRefreshing ? [filterItem, indicatorItem] : [filterItem]
        if navigationItem.leftBarButtonItems?.count != items.count {
            navigationItem.leftBarButtonItems = items
        }
    }

    private func updateStarItem() {
        guard let article = currentArticle() else { return }
        starItem.image = UIImage(systemName: article.isStarred ? "star.fill" : "star")
        starItem.accessibilityLabel = article.isStarred
            ? String(localized: "Unstar article") : String(localized: "Star article")
    }

    // MARK: - Data

    func configure(articles: [Article], index: Int) {
        self.articles = articles
        self.index = clamp(index)
        loadViewIfNeeded()
        if let page = makePage(for: self.index) {
            pageController.setViewControllers([page], direction: .forward, animated: false)
        }
        updateStarItem()
    }

    func update(articles: [Article], index: Int) {
        self.articles = articles
        guard !isTransitioning else { return }
        let target = clamp(index)
        let displayedID = displayedWebVC?.article.identifier
        let targetID = articles.indices.contains(target) ? articles[target].identifier : nil
        self.index = target
        guard displayedID != targetID, let page = makePage(for: target) else {
            updateStarItem(); return
        }
        pageController.setViewControllers([page], direction: .forward, animated: false)
        updateStarItem()
    }

    private func clamp(_ i: Int) -> Int { min(max(i, 0), max(0, articles.count - 1)) }

    private func currentArticle() -> Article? {
        guard articles.indices.contains(index) else { return nil }
        return articles[index]
    }

    private func makePage(for index: Int) -> ReaderWebViewController? {
        guard articles.indices.contains(index) else { return nil }
        let vc = ReaderWebViewController(
            article: articles[index],
            allowsFullscreen: isFullscreenAvailable,
            onRefresh: onRefresh,
            onRequestShowBars: { [weak self] in self?.applyFullscreen(false, animated: true) }
        )
        vc.hideBarsTapZonesActive(settings.articleFullscreenEnabled && isFullscreenAvailable)
        return vc
    }

    // MARK: - Actions

    @objc private func showFilter() { onShowFilter?() }
    @objc private func showSettings() { onShowSettings?() }

    @objc private func toggleStar() {
        guard let article = currentArticle() else { return }
        onToggleStar?(article)
        updateStarItem()
    }

    private func buildMenuActions() -> [UIMenuElement] {
        guard let article = currentArticle() else { return [] }
        let config = ReaderMenuBuilder.config(
            hasURL: !article.url.isEmpty, hasFeed: article.feed != nil, aiReady: aiReady
        )
        var actions: [UIMenuElement] = []

        actions.append(UIAction(
            title: String(localized: "Force update"),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in self?.onRefresh?() })

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

        if config.showGoToFeed, let feed = article.feed {
            actions.append(UIAction(
                title: String(localized: "Go to feed"),
                image: UIImage(systemName: "dot.radiowaves.up.forward")
            ) { [weak self] _ in self?.onGoToFeed?(feed) })
        }

        return actions
    }

    func reloadCurrentPage() {
        displayedWebVC?.reload()
    }

    @objc private func shareArticle() {
        guard let article = currentArticle(), let url = URL(string: article.url) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = shareItem
        present(activity, animated: true)
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
        isTransitioning = true
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        isTransitioning = false
        guard completed, let vc = displayedWebVC,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles) else { return }
        index = i
        updateStarItem()
        onIndexChange?(i)
    }
}
