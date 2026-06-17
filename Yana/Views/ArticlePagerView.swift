import SwiftUI
import UIKit
import WebKit

/// Horizontal pager over the timeline. Each page is an `ArticleContentView` whose web view
/// owns vertical scrolling and pinch-to-zoom; a horizontal pan drives an interactive
/// navigation-style push/pop (the next article slides in over the current with parallax and
/// a leading shadow; the previous one is revealed underneath) so moving through the timeline
/// feels like standard iOS navigation. Only the visible page and the transient neighbour are
/// kept alive, so an endless timeline never instantiates a web view per article.
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

/// Drives the interactive push/pop transition between article pages.
@MainActor
final class ArticlePagerController: UIViewController, UIGestureRecognizerDelegate {
    /// How far the outgoing/underlying page shifts relative to the incoming one — matches the
    /// parallax UINavigationController uses for push/pop.
    private let parallax: CGFloat = 0.3

    var onIndexChange: ((Int) -> Void)?

    private var articles: [Article] = []
    private var index = 0
    private var onRefresh: (() -> Void)?

    private var current: ArticlePage?
    private var incoming: ArticlePage?
    /// +1 while pushing toward the next article, -1 while popping toward the previous one.
    private var direction = 0
    private var isFinishing = false

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let pan = HorizontalPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        // Yield horizontal drags to the web view while it can scroll sideways (zoomed in or
        // content wider than the screen), so panning a zoomed article doesn't flip pages.
        pan.shouldYieldHorizontally = { [weak self] in self?.currentWebViewScrollsHorizontally ?? false }
        view.addGestureRecognizer(pan)
    }

    /// Whether the displayed article's web view can currently scroll horizontally.
    private var currentWebViewScrollsHorizontally: Bool {
        guard let root = current?.view,
              let scrollView = Self.webScrollView(in: root) else { return false }
        return scrollView.contentSize.width > scrollView.bounds.width + 1
    }

    private static func webScrollView(in view: UIView) -> UIScrollView? {
        if let webView = view as? WKWebView { return webView.scrollView }
        for subview in view.subviews {
            if let found = webScrollView(in: subview) { return found }
        }
        return nil
    }

    func configure(articles: [Article], index: Int, onRefresh: (() -> Void)?) {
        self.articles = articles
        self.index = index
        self.onRefresh = onRefresh
        loadViewIfNeeded()
        if let page = makePage(for: index) {
            current = page
            addPage(page, above: nil)
        }
    }

    func update(articles: [Article], index: Int, onRefresh: (() -> Void)?) {
        self.onRefresh = onRefresh
        self.articles = articles
        // Never reshuffle pages mid-gesture.
        guard !isFinishing, incoming == nil else { return }

        let displayedID = current?.article.identifier
        let targetID = articles.indices.contains(index) ? articles[index].identifier : nil
        self.index = index
        guard displayedID != targetID else { return }
        swapCurrent(to: index)
    }

    // MARK: - Pages

    private func makePage(for index: Int) -> ArticlePage? {
        guard articles.indices.contains(index) else { return nil }
        return ArticlePage(article: articles[index], onRefresh: onRefresh)
    }

    /// Adds a page as a child VC. `above` controls z-order; `nil` appends on top.
    private func addPage(_ page: ArticlePage, above sibling: ArticlePage?) {
        addChild(page)
        if let sibling { view.insertSubview(page.view, belowSubview: sibling.view) }
        else { view.addSubview(page.view) }
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        page.view.transform = .identity
        page.didMove(toParent: self)
    }

    private func removePage(_ page: ArticlePage) {
        page.willMove(toParent: nil)
        page.view.removeFromSuperview()
        page.removeFromParent()
    }

    /// Replaces the current page instantly (no animation) — used for programmatic moves such
    /// as restoring the saved position or clamping after a filter change.
    private func swapCurrent(to index: Int) {
        guard let page = makePage(for: index) else { return }
        current.map(removePage)
        current = page
        addPage(page, above: nil)
    }

    // MARK: - Interactive transition

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = view.bounds.width
        guard width > 0 else { return }
        let tx = gesture.translation(in: view).x

        switch gesture.state {
        case .changed:
            if incoming == nil { beginTransition(translationX: tx) }
            guard let current, let incoming else { return }
            apply(progress: progress(tx: tx, width: width), width: width, current: current, incoming: incoming)
        case .ended, .cancelled, .failed:
            finish(gesture: gesture, width: width)
        default:
            break
        }
    }

    private func beginTransition(translationX tx: CGFloat) {
        guard let current, !isFinishing else { return }
        let width = view.bounds.width

        if tx < 0, index < articles.count - 1, let page = makePage(for: index + 1) {
            // Push: the next page slides in from the right, on top of the current one.
            direction = 1
            incoming = page
            addPage(page, above: nil)
            page.view.transform = CGAffineTransform(translationX: width, y: 0)
            applyShadow(to: page.view)
        } else if tx > 0, index > 0, let page = makePage(for: index - 1) {
            // Pop: the previous page sits underneath; the current one slides off to reveal it.
            direction = -1
            incoming = page
            addPage(page, above: current)
            page.view.transform = CGAffineTransform(translationX: -width * parallax, y: 0)
            applyShadow(to: current.view)
        }
    }

    private func progress(tx: CGFloat, width: CGFloat) -> CGFloat {
        let raw = direction == 1 ? -tx / width : tx / width
        return min(max(raw, 0), 1)
    }

    private func apply(progress p: CGFloat, width: CGFloat, current: ArticlePage, incoming: ArticlePage) {
        if direction == 1 {
            incoming.view.transform = CGAffineTransform(translationX: width * (1 - p), y: 0)
            current.view.transform = CGAffineTransform(translationX: -width * parallax * p, y: 0)
        } else {
            current.view.transform = CGAffineTransform(translationX: width * p, y: 0)
            incoming.view.transform = CGAffineTransform(translationX: -width * parallax * (1 - p), y: 0)
        }
    }

    private func finish(gesture: UIPanGestureRecognizer, width: CGFloat) {
        guard let current, let incoming else { return }
        let p = progress(tx: gesture.translation(in: view).x, width: width)
        let directionalVelocity = direction == 1 ? -gesture.velocity(in: view).x : gesture.velocity(in: view).x
        let complete = p > 0.4 || directionalVelocity > 800
        let movedDirection = direction

        isFinishing = true
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.apply(progress: complete ? 1 : 0, width: width, current: current, incoming: incoming)
        } completion: { _ in
            self.clearShadow(from: current.view)
            self.clearShadow(from: incoming.view)
            if complete {
                self.removePage(current)
                incoming.view.transform = .identity
                self.current = incoming
                self.index += movedDirection
                self.onIndexChange?(self.index)
            } else {
                self.removePage(incoming)
                current.view.transform = .identity
            }
            self.incoming = nil
            self.direction = 0
            self.isFinishing = false
        }
    }

    // MARK: - Shadow (leading edge of the topmost moving page)

    private func applyShadow(to v: UIView) {
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOffset = CGSize(width: -3, height: 0)
        v.layer.shadowRadius = 6
        v.layer.shadowOpacity = 0.18
        v.layer.shadowPath = UIBezierPath(rect: v.bounds).cgPath
    }

    private func clearShadow(from v: UIView) {
        v.layer.shadowOpacity = 0
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Let the horizontal pan coexist with the web view's own vertical scroll and pinch.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// A pan recognizer that fails as soon as the gesture is clearly vertical, so vertical drags
/// pass through to the article's scroll view (and two-finger pinches are ignored entirely).
@MainActor
final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    /// Asked once per gesture, when it first reads as horizontal: return `true` to fail (and
    /// let the underlying scroll view take the drag instead of paging).
    var shouldYieldHorizontally: (() -> Bool)?

    private var decided = false

    override func reset() {
        super.reset()
        decided = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard !decided, state != .failed else { return }
        let t = translation(in: view)
        guard abs(t.x) + abs(t.y) > 12 else { return }
        decided = true
        if abs(t.y) > abs(t.x) || shouldYieldHorizontally?() == true { state = .failed }
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
