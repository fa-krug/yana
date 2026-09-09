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
    /// The latest "Find in Article" menu command (see `ReaderFindRequest`); applied once per token.
    var findRequest: ReaderFindRequest?
    var onRefresh: (() -> Void)?
    /// True when the reader pane owns keyboard focus; drives first-responder so Esc/scroll keys reach it.
    var isFocused: Bool = false
    /// Called when the user presses Esc inside the reader to hand focus back to the sidebar.
    var onEscape: () -> Void = {}

    func makeUIViewController(context: Context) -> MacReaderContainerViewController {
        let vc = MacReaderContainerViewController()
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        vc.onEscape = onEscape
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastFindToken = findRequest?.token
        vc.show(articles: articles, index: index)
        return vc
    }

    func updateUIViewController(_ vc: MacReaderContainerViewController, context: Context) {
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        vc.onEscape = onEscape
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            vc.reloadCurrent()
        }
        vc.show(articles: articles, index: index)
        if let findRequest, findRequest.token != context.coordinator.lastFindToken {
            context.coordinator.lastFindToken = findRequest.token
            vc.handleFindRequest(findRequest.kind)
        }
        // Never steal focus back from the find field: it is inside this controller's view but is
        // not the controller itself, and every SwiftUI update passes through here while it has focus.
        if isFocused, !vc.isFirstResponder, !vc.isFindFieldFocused { vc.becomeFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var lastReloadToken = 0
        var lastFindToken: Int?
    }
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
    var onEscape: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))]
    }

    /// Esc closes an open find bar first; only a second Esc hands focus back to the sidebar.
    @objc private func handleEscape() {
        if isFindActive { endFind() } else { onEscape?() }
    }

    // MARK: - Find in article

    /// The "Find in Article" bar, docked at the top of the detail pane (Safari's placement on the
    /// Mac). Built on first use; the pages get a matching top safe-area inset while it is up so the
    /// body scrolls under it rather than being covered by it.
    private var findBar: ReaderFindBar?
    private var findBarTopConstraint: NSLayoutConstraint?
    private(set) var isFindActive = false

    /// Whether the find field has keyboard focus -- `MacReaderDetailView` must not pull first
    /// responder back to this controller while it does.
    var isFindFieldFocused: Bool { findBar?.isFieldFocused ?? false }

    /// A menu-bar command (see `ReaderFindRequest`). ⌘G/⇧⌘G with the bar closed open it, matching
    /// how Safari treats Find Next with no search up.
    func handleFindRequest(_ kind: ReaderFindRequest.Kind) {
        switch kind {
        case .begin:
            beginFind()
        case .next:
            if isFindActive { findBar?.onNext?() } else { beginFind() }
        case .previous:
            if isFindActive { findBar?.onPrevious?() } else { beginFind() }
        }
    }

    func beginFind() {
        guard currentIdentifier != nil else { return }
        let bar = findBar ?? installFindBar()
        if !isFindActive {
            isFindActive = true
            bar.isHidden = false
            view.setNeedsLayout()
            syncFindWithCurrentPage()
        }
        bar.focusField()
    }

    func endFind() {
        guard isFindActive else { return }
        isFindActive = false
        findBar?.resignFirstResponder()
        findBar?.isHidden = true
        for page in cache.values { page.endFind() }
        updateFindInsets()
        // Hand keyboard focus back to the pane, so the arrow/Esc keys keep working.
        becomeFirstResponder()
    }

    private func installFindBar() -> ReaderFindBar {
        let bar = ReaderFindBar(separatorEdge: .bottom)
        bar.isHidden = true
        bar.onQueryChange = { [weak self] query in
            self?.currentPage?.setFindQuery(query)
            self?.updateFindStatus()
        }
        bar.onNext = { [weak self] in
            self?.currentPage?.findNext()
            self?.updateFindStatus()
        }
        bar.onPrevious = { [weak self] in
            self?.currentPage?.findPrevious()
            self?.updateFindStatus()
        }
        bar.onDone = { [weak self] in self?.endFind() }
        view.addSubview(bar)
        // Pinned below whatever safe area this pane inherits (never under the window toolbar), but
        // not to `safeAreaLayoutGuide` itself: that guide includes the inset this bar adds, which
        // would push the bar down by its own height. `viewSafeAreaInsetsDidChange` keeps the
        // constant at the inherited part only.
        let top = bar.topAnchor.constraint(equalTo: view.topAnchor, constant: inheritedTopInset)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top,
        ])
        findBarTopConstraint = top
        findBar = bar
        return bar
    }

    private var currentPage: ReaderBlockViewController? {
        guard let id = currentIdentifier else { return nil }
        return cache[id]
    }

    /// The safe area this pane inherits from its ancestors, without the part it adds itself.
    private var inheritedTopInset: CGFloat {
        view.safeAreaInsets.top - additionalSafeAreaInsets.top
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        findBarTopConstraint?.constant = inheritedTopInset
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFindInsets()
    }

    /// Reserve the bar's height in the pages' top safe area while it is up (see `beginFind`).
    private func updateFindInsets() {
        let top: CGFloat = (isFindActive && findBar?.isHidden == false) ? (findBar?.bounds.height ?? 0) : 0
        let insets = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if additionalSafeAreaInsets != insets { additionalSafeAreaInsets = insets }
    }

    /// Re-run the bar's query on the newly selected article and clear every other cached page, so
    /// clicking through the sidebar carries the search along (each page lands on its first match).
    private func syncFindWithCurrentPage() {
        guard isFindActive, let bar = findBar else { return }
        let current = currentPage
        for page in cache.values where page !== current { page.endFind() }
        current?.setFindQuery(bar.query)
        updateFindStatus()
    }

    private func updateFindStatus() {
        guard isFindActive else { return }
        findBar?.setStatus(currentPage?.findStatus ?? .idle)
    }

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
            syncFindWithCurrentPage()
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
        updateFindStatus()
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
        endFind()
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
