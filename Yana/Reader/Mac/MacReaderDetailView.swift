#if os(macOS)
import SwiftUI
import AppKit

/// The Mac window's detail pane (Option C): shows exactly one selected article at a time instead of
/// the iOS `UIPageViewController` swipe pager. Sidebar selection drives which article renders; the
/// horizontal-swipe navigation of iOS is replaced by the permanent sidebar list.
///
/// It reuses `ReaderBlockViewController` verbatim as the page renderer — the pager-only concessions
/// (`allowsFullscreen`, tap-to-hide zones, first-paint text deferral) simply stay dormant on Mac.
///
/// The whole file is `#if os(macOS)`: it was already Mac-only in practice, and every type it now
/// touches (`NSViewControllerRepresentable`, `NSViewController`) exists on one platform.
struct MacReaderDetailView: NSViewControllerRepresentable {
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

    func makeNSViewController(context: Context) -> MacReaderContainerViewController {
        let vc = MacReaderContainerViewController()
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        vc.onEscape = onEscape
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastFindToken = findRequest?.token
        vc.show(articles: articles, index: index)
        return vc
    }

    func updateNSViewController(_ vc: MacReaderContainerViewController, context: Context) {
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
        if isFocused, !vc.isCurrentFirstResponder, !vc.isFindFieldFocused { vc.takeFirstResponder() }
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
final class MacReaderContainerViewController: NSViewController {
    var resolveArticle: ((ArticleSummary) -> Article?)?
    var onRefresh: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// First responder is a property of the *window*, not of a responder, so both of UIKit's
    /// `isFirstResponder` / `becomeFirstResponder()` have to be asked of the window instead. Named
    /// differently from the AppKit `becomeFirstResponder()` they are not — that one is a callback
    /// AppKit invokes to ask permission, and overriding it to force a change would be wrong.
    var isCurrentFirstResponder: Bool { view.window?.firstResponder === self }

    func takeFirstResponder() { view.window?.makeFirstResponder(self) }

    /// Esc closes an open find bar first; only a second Esc hands focus back to the sidebar.
    ///
    /// AppKit routes Esc to `cancelOperation(_:)` down the responder chain by itself, so this
    /// replaces the UIKit version's explicit `keyCommands` / `UIKeyCommand.inputEscape` entry.
    override func cancelOperation(_ sender: Any?) {
        if isFindActive { endFind() } else { onEscape?() }
    }

    // MARK: - Find in article

    /// The "Find in Article" bar, docked at the top of the detail pane (Safari's placement on the
    /// Mac). Built on first use.
    ///
    /// **The bar reserves its own footprint with a constraint, not with a safe-area inset.**
    /// `additionalSafeAreaInsets` — how the UIKit version did it, and how the iOS pager still does —
    /// does not exist on macOS. What it bought was "the body scrolls *under* the bar but never
    /// starts hidden behind it"; pinning the page's top edge to the bar's bottom edge instead gives
    /// the stronger, simpler arrangement the Mac actually wants, chrome above content rather than
    /// chrome overlaying it. That is also why there is no `inheritedTopInset` /
    /// `viewSafeAreaInsetsDidChange` pair any more: with no inset of its own to subtract back out,
    /// there is nothing to keep in sync.
    private var findBar: ReaderFindBar?
    private(set) var isFindActive = false

    /// The page area's top edge, pinned to the container while the bar is down and to the bar's
    /// bottom while it is up. Exactly one of the two is ever active.
    private var contentTopToContainer: NSLayoutConstraint!
    private var contentTopToFindBar: NSLayoutConstraint?

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
            applyFindLayout()
            syncFindWithCurrentPage()
        }
        bar.focusField()
    }

    func endFind() {
        guard isFindActive else { return }
        isFindActive = false
        findBar?.isHidden = true
        for page in cache.values { page.endFind() }
        applyFindLayout()
        // Hand keyboard focus back to the pane, so the arrow/Esc keys keep working. This is also
        // what resigns the find field: the window can only have one first responder.
        takeFirstResponder()
    }

    /// Swap which of the two top constraints holds, and let the change animate with the window's
    /// own layout pass.
    private func applyFindLayout() {
        contentTopToContainer.isActive = !isFindActive
        contentTopToFindBar?.isActive = isFindActive
        view.needsLayout = true
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
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Below whatever safe area this pane inherits, so the bar never lands under the window
            // toolbar. On macOS this guide reflects only what the *window* imposes — the bar adds
            // nothing to it, which is precisely why the inherited-versus-own bookkeeping the UIKit
            // version needed has no counterpart here.
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        contentTopToFindBar = contentContainer.topAnchor.constraint(equalTo: bar.bottomAnchor)
        findBar = bar
        return bar
    }

    private var currentPage: ReaderBlockViewController? {
        guard let id = currentIdentifier else { return nil }
        return cache[id]
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
    private var currentChild: NSViewController?
    private var lastIndex: Int?

    /// The area a page fills. A dedicated subview (rather than adding pages straight to `view`)
    /// keeps the find-bar constraint independent of child swaps — the top edge is negotiated once,
    /// not rebuilt every time the selection changes.
    private let contentContainer = NSView()

    private lazy var placeholder = makePlaceholder()

    override func loadView() {
        // A plain `NSView` would do, except that `viewDidChangeEffectiveAppearance()` is declared on
        // `NSView` and not on `NSViewController` — so a controller that paints its background into a
        // layer has no other way to learn that light/dark mode changed under it.
        let view = MacReaderBackgroundView()
        view.wantsLayer = true
        view.onAppearanceChange = { [weak self] in self?.applyBackgroundColor() }
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundColor()

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        contentTopToContainer = contentContainer.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentTopToContainer,
        ])
    }

    /// A layer-backed background does not follow the system appearance on its own — an `NSColor`
    /// resolved to a `CGColor` is frozen at the moment it was resolved — so re-resolve it whenever
    /// light/dark mode changes under the window (see `MacReaderBackgroundView`).
    private func applyBackgroundColor() {
        view.layer?.backgroundColor = PlatformColor.yanaWindowBackground.cgColor
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

    /// AppKit has no `willMove(toParent:)` / `didMove(toParent:)`: `addChild(_:)` and
    /// `removeFromParent()` are the whole containment contract, and the view is parented separately.
    private func swapIn(_ vc: NSViewController) {
        removeCurrentChild()
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentChild = vc
    }

    /// Detach the visible child from the hierarchy WITHOUT dropping it from `cache`, so its scroll
    /// position survives until it is evicted.
    private func removeCurrentChild() {
        guard let child = currentChild else { return }
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
            // Touching `view` is AppKit's `loadViewIfNeeded()`: the getter loads the view if it has
            // not been loaded, which is the off-screen layout this prewarm is buying.
            _ = vc.view
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

    private func makePlaceholder() -> NSViewController {
        NSHostingController(rootView: MacReaderPlaceholder())
    }
}

/// The container's own view. Exists only to forward `viewDidChangeEffectiveAppearance()`, which
/// AppKit declares on `NSView` rather than on `NSViewController`. Mirrors the same trick
/// `ReaderBlockViewControllerMacOS` uses for the page background.
private final class MacReaderBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
