import SwiftUI
import UIKit

/// The Mac window's detail pane (Option C): shows exactly one selected article at a time instead of
/// the iOS `UIPageViewController` swipe pager. Sidebar selection drives which article renders; the
/// horizontal-swipe navigation of iOS is replaced by the permanent sidebar list.
///
/// It reuses `ReaderBlockViewController` verbatim as the page renderer — the pager-only concessions
/// (`allowsFullscreen`, tap-to-hide zones, first-paint text deferral) simply stay dormant on Mac.
struct MacReaderDetailView: UIViewControllerRepresentable {
    let articles: [ArticleSummary]
    let index: Int
    let resolveArticle: (ArticleSummary) -> Article?
    /// Bumped by the host after a summary / force-reload writes new content so the visible page
    /// re-renders (same mechanism as the iOS `ReaderHostView.reloadToken`).
    let reloadToken: Int
    var onRefresh: (() -> Void)?

    func makeUIViewController(context: Context) -> MacReaderContainerViewController {
        let vc = MacReaderContainerViewController()
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        context.coordinator.lastReloadToken = reloadToken
        vc.show(articles: articles, index: index)
        return vc
    }

    func updateUIViewController(_ vc: MacReaderContainerViewController, context: Context) {
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            vc.reloadCurrent()
        }
        vc.show(articles: articles, index: index)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator { var lastReloadToken = 0 }
}

/// Hosts one `ReaderBlockViewController` child at a time and swaps it when the selected article
/// changes. A small **LRU cache of child VCs keyed by article identifier** does three jobs at once:
///
/// 1. **Prewarm** — `PrewarmPlan` decides which neighbor articles to build into the cache ahead of a
///    selection move, so arrow-key / next-previous navigation swaps in an already-built page.
/// 2. **Scroll memory** — revisiting a recently-viewed article restores its exact scroll offset,
///    because its child VC (and the scroll view inside it) is still cached.
/// 3. **Instant swaps** — a selection change is just re-parenting a cached child, no rebuild.
@MainActor
final class MacReaderContainerViewController: UIViewController {
    var resolveArticle: ((ArticleSummary) -> Article?)?
    var onRefresh: (() -> Void)?

    /// Cache of built page VCs keyed by article identifier; `lruOrder` tracks recency (last = MRU).
    private var cache: [String: ReaderBlockViewController] = [:]
    private var lruOrder: [String] = []
    private let cacheLimit = 5
    private let prewarmRadius = 2

    private var currentIdentifier: String?
    private var currentChild: UIViewController?
    private var lastIndex: Int?

    private lazy var placeholder = makePlaceholder()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    /// Render `articles[index]`, swapping the child only when the selected identifier actually
    /// changes, then prewarm neighbors and trim the cache.
    func show(articles: [ArticleSummary], index: Int) {
        guard articles.indices.contains(index) else {
            showPlaceholder()
            currentIdentifier = nil
            lastIndex = nil
            return
        }
        let summary = articles[index]
        if currentIdentifier != summary.identifier {
            guard let vc = pageViewController(for: summary) else { showPlaceholder(); return }
            swapIn(vc)
            currentIdentifier = summary.identifier
            touch(summary.identifier)
        }

        let direction: PrewarmPlan.Direction
        if let last = lastIndex {
            direction = index > last ? .forward : (index < last ? .backward : .none)
        } else {
            direction = .none
        }
        lastIndex = index
        prewarm(around: index, in: articles, direction: direction)
        trimCache()
    }

    /// Force the visible page to re-render (its article's content changed underneath it).
    func reloadCurrent() {
        guard let id = currentIdentifier else { return }
        cache[id]?.reload()
    }

    // MARK: - Child management

    private func pageViewController(for summary: ArticleSummary) -> ReaderBlockViewController? {
        if let cached = cache[summary.identifier] { return cached }
        guard let article = resolveArticle?(summary) else { return nil }
        let vc = ReaderBlockViewController(
            article: article,
            allowsFullscreen: false,   // no tap-to-hide fullscreen on Mac
            onRefresh: { [weak self] in self?.onRefresh?() },
            onRequestShowBars: {}      // no hidden bars to restore on Mac
        )
        cache[summary.identifier] = vc
        return vc
    }

    private func swapIn(_ vc: UIViewController) {
        removeCurrentChild()
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        vc.didMove(toParent: self)
        currentChild = vc
    }

    /// Detach the visible child from the hierarchy WITHOUT dropping it from `cache`, so its scroll
    /// position survives until it is evicted.
    private func removeCurrentChild() {
        guard let child = currentChild else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        currentChild = nil
    }

    private func showPlaceholder() {
        guard currentChild !== placeholder else { return }
        swapIn(placeholder)
        currentIdentifier = nil
    }

    // MARK: - LRU + prewarm

    private func touch(_ identifier: String) {
        lruOrder.removeAll { $0 == identifier }
        lruOrder.append(identifier)
    }

    /// Build neighbor pages into the cache ahead of a selection move so the next swap is instant.
    /// Reuses the pure, tested `PrewarmPlan`; "prewarm index N" here means "instantiate + lay out
    /// page N off-screen", which also warms its images via the SwiftUI render.
    private func prewarm(around index: Int, in articles: [ArticleSummary], direction: PrewarmPlan.Direction) {
        let neighbors = PrewarmPlan.indices(
            current: index, count: articles.count, radius: prewarmRadius, direction: direction
        )
        for n in neighbors where articles.indices.contains(n) {
            let summary = articles[n]
            guard cache[summary.identifier] == nil, let vc = pageViewController(for: summary) else {
                if cache[articles[n].identifier] != nil { touch(articles[n].identifier) }
                continue
            }
            vc.loadViewIfNeeded()   // force an off-screen layout so the swap-in paints immediately
            touch(summary.identifier)
        }
    }

    /// Evict least-recently-used pages beyond the cap, never the visible one.
    private func trimCache() {
        while lruOrder.count > cacheLimit {
            guard let evict = lruOrder.first(where: { $0 != currentIdentifier }) else { break }
            lruOrder.removeAll { $0 == evict }
            cache.removeValue(forKey: evict)
        }
    }

    // MARK: - Placeholder

    private func makePlaceholder() -> UIViewController {
        let host = UIHostingController(rootView: MacReaderPlaceholder())
        host.view.backgroundColor = .systemBackground
        return host
    }
}

/// Shown in the detail pane when no article is selected (e.g. a filter emptied the timeline).
private struct MacReaderPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "No Article Selected",
            systemImage: "doc.text",
            description: Text("Select an article from the list.")
        )
    }
}
