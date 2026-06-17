import SwiftUI
import UIKit

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

    private var clampedIndex: Int {
        min(max(currentIndex, 0), max(0, articles.count - 1))
    }

    func makeUIViewController(context: Context) -> ArticlePagerController {
        let controller = ArticlePagerController()
        controller.onIndexChange = { currentIndex = $0 }
        controller.configure(articles: articles, index: clampedIndex, onRefresh: onRefresh)
        return controller
    }

    func updateUIViewController(_ controller: ArticlePagerController, context: Context) {
        controller.onIndexChange = { currentIndex = $0 }
        controller.update(articles: articles, index: clampedIndex, onRefresh: onRefresh)
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

    func configure(articles: [Article], index: Int, onRefresh: (() -> Void)?) {
        self.articles = articles
        self.index = index
        self.onRefresh = onRefresh
        loadViewIfNeeded()
        if let page = makePage(for: index) {
            pageController.setViewControllers([page], direction: .forward, animated: false)
        }
    }

    func update(articles: [Article], index: Int, onRefresh: (() -> Void)?) {
        self.onRefresh = onRefresh
        self.articles = articles
        // Never reshuffle pages mid-swipe.
        guard !isTransitioning else { return }

        let displayedID = displayedPage?.article.identifier
        let targetID = articles.indices.contains(index) ? articles[index].identifier : nil
        self.index = index
        guard displayedID != targetID, let page = makePage(for: index) else { return }
        // Programmatic move (restore anchor / clamp after a filter change): no animation.
        pageController.setViewControllers([page], direction: .forward, animated: false)
    }

    // MARK: - Pages

    private var displayedPage: ArticlePage? {
        pageController.viewControllers?.first as? ArticlePage
    }

    private func makePage(for index: Int) -> ArticlePage? {
        guard articles.indices.contains(index) else { return nil }
        return ArticlePage(article: articles[index], onRefresh: onRefresh)
    }

    private func displayedIndex(of page: ArticlePage) -> Int? {
        TimelinePageIndex.index(of: page.article.identifier, in: articles)
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
    }
}

/// Hosts an `ArticleContentView` and remembers which article it shows, so the pager can tell
/// whether the displayed article still matches the timeline after the list changes.
final class ArticlePage: UIHostingController<ArticleContentView> {
    let article: Article

    init(article: Article, onRefresh: (() -> Void)?) {
        self.article = article
        super.init(rootView: ArticleContentView(article: article, onRefresh: onRefresh))
        view.backgroundColor = .systemBackground
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
