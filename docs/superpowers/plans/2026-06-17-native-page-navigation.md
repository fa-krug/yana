# Native Page Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the article reader's hand-rolled push/pop-parallax transition with a native `UIPageViewController(.scroll)` so timeline navigation uses iOS's own smooth edge-to-edge paging, and make the reader's top/bottom bars transparent over the article.

**Architecture:** `ArticlePagerView` keeps its exact `UIViewControllerRepresentable` API; only the underlying `ArticlePagerController` is rewritten to host a child `UIPageViewController` (scroll style, horizontal) as its data source + delegate. A pure index-lookup helper maps a displayed page back to its timeline index. The page controller's internal scroll view is disabled while the current article's web view can scroll horizontally (zoom/wide content), reproducing today's "don't flip a zoomed article" behavior.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, UIKit (`UIPageViewController`), WebKit (`WKWebView`), Swift Testing.

## Global Constraints

- Platform: iOS 26.0+ (iPhone and iPad).
- Swift 6 strict concurrency; `@MainActor` annotations throughout.
- No new user-facing strings are introduced by this plan, so **no** `Localizable.xcstrings` changes are needed. If any step would add a user-facing string, it must be added to the catalog with a `de` translation marked `"state" : "translated"`.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` (use `build` instead of `test` for build-only checks).
- `Article.identifier` is a non-optional `String` (dedup key).
- Keep `ArticlePagerView`'s public signature unchanged so `ArticleReaderView` needs no edits to its pager call site.

---

## File Structure

- `Yana/Utilities/TimelineFiltering.swift` — **modify**: add `TimelinePageIndex.index(of:in:) -> Int?`; refactor `TimelineAnchor.index(for:in:)` to delegate to it.
- `Yana/Views/ArticlePagerView.swift` — **rewrite** `ArticlePagerController` around `UIPageViewController`; delete the custom transition/gesture/shadow code. `ArticlePagerView` and `ArticlePage` stay (minor changes only).
- `Yana/Views/ArticleReaderView.swift` — **modify**: hide the top navigation bar background.
- `Yana/Views/ArticleContentView.swift` — **inspect/modify only if needed** for the bottom bar background.
- `YanaTests/TimelinePageIndexTests.swift` — **create**: unit tests for the pure helper.

---

## Task 1: Pure timeline index helper

**Files:**
- Modify: `Yana/Utilities/TimelineFiltering.swift`
- Test: `YanaTests/TimelinePageIndexTests.swift`

**Interfaces:**
- Produces: `enum TimelinePageIndex { static func index(of identifier: String?, in articles: [Article]) -> Int? }` — returns the index of the article whose `identifier` matches, or `nil` if `identifier` is `nil`/absent.
- `TimelineAnchor.index(for:in:)` keeps its existing signature `(String?, [Article]) -> Int` and behavior (0 fallback), now implemented via `TimelinePageIndex`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/TimelinePageIndexTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Timeline page index")
struct TimelinePageIndexTests {
    private func article(_ id: String) -> Article {
        Article(title: id, identifier: id, url: "https://x.com/\(id)")
    }

    @Test func returnsIndexOfMatchingIdentifier() {
        let list = [article("a"), article("b"), article("c")]
        #expect(TimelinePageIndex.index(of: "a", in: list) == 0)
        #expect(TimelinePageIndex.index(of: "c", in: list) == 2)
    }

    @Test func returnsNilWhenAbsentOrNil() {
        let list = [article("a"), article("b")]
        #expect(TimelinePageIndex.index(of: "missing", in: list) == nil)
        #expect(TimelinePageIndex.index(of: nil, in: list) == nil)
        #expect(TimelinePageIndex.index(of: "a", in: []) == nil)
    }

    @Test func anchorStillFallsBackToZero() {
        let list = [article("a"), article("b")]
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        #expect(TimelineAnchor.index(for: "missing", in: list) == 0)
        #expect(TimelineAnchor.index(for: nil, in: list) == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelinePageIndexTests`
Expected: FAIL — compile error, `TimelinePageIndex` is not defined.

- [ ] **Step 3: Add the helper and refactor `TimelineAnchor`**

In `Yana/Utilities/TimelineFiltering.swift`, replace the `TimelineAnchor` enum (lines 17-25) with:

```swift
/// Resolves an article `identifier` to its index in the currently displayed list.
/// Returns `nil` when the identifier is missing — used by the pager's data source to
/// decide whether a neighbouring page exists.
enum TimelinePageIndex {
    static func index(of identifier: String?, in articles: [Article]) -> Int? {
        guard let identifier else { return nil }
        return articles.firstIndex { $0.identifier == identifier }
    }
}

/// Resolves the persisted timeline anchor (an article `identifier`) to an index in the
/// currently displayed list, falling back to 0 (newest) when it is missing.
enum TimelineAnchor {
    static func index(for identifier: String?, in articles: [Article]) -> Int {
        TimelinePageIndex.index(of: identifier, in: articles) ?? 0
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelinePageIndexTests`
Expected: PASS (3 tests). Also confirm the existing `TimelineFilteringTests` still pass:
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineFilteringTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/TimelineFiltering.swift YanaTests/TimelinePageIndexTests.swift
git commit -m "feat: add TimelinePageIndex helper for pager data source"
```

---

## Task 2: Rewrite the pager around UIPageViewController

**Files:**
- Modify: `Yana/Views/ArticlePagerView.swift` (rewrite `ArticlePagerController`; delete custom-transition code)

**Interfaces:**
- Consumes: `TimelinePageIndex.index(of:in:)` (Task 1); `ArticlePage(article:onRefresh:)` (unchanged, defined in this file).
- Produces: `ArticlePagerController` with `configure(articles:index:onRefresh:)`, `update(articles:index:onRefresh:)`, and `var onIndexChange: ((Int) -> Void)?` — the same surface `ArticlePagerView` already calls.

This task replaces everything in `Yana/Views/ArticlePagerView.swift` *except* the `ArticlePagerView` struct (top of file) and the `ArticlePage` class (bottom of file). The zoom/wide paging lock is added in Task 3; this task leaves paging always enabled.

- [ ] **Step 1: Replace the controller implementation**

In `Yana/Views/ArticlePagerView.swift`, keep the `ArticlePagerView` struct as-is. Replace the entire `ArticlePagerController` class **and** the `HorizontalPanGestureRecognizer` class (everything between the `ArticlePagerView` struct and the `ArticlePage` class) with:

```swift
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. (If the compiler flags the now-unused static `webScrollView(in:)` finder — it is reintroduced in Task 3; if it was removed with the old code, that is fine, Task 3 re-adds it.)

- [ ] **Step 3: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (all existing tests; no pager tests exist).

- [ ] **Step 4: Manual verification in the simulator**

Launch the app (Yana scheme). Verify:
- Swiping left/right pages between articles with the native edge-to-edge scroll animation (no parallax/shadow overlay).
- The position is remembered: swipe a few articles, kill and relaunch — it reopens on the same article.
- Open the filter sheet, disable a tag so the list shrinks; on dismiss the reader stays on a valid article (no crash, no blank page).
- Pull-to-refresh still works on a page; the bottom Open-in-Browser / Share buttons still work.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/ArticlePagerView.swift
git commit -m "feat: page the article timeline with a native UIPageViewController"
```

---

## Task 3: Lock paging while a web view scrolls horizontally

**Files:**
- Modify: `Yana/Views/ArticlePagerView.swift` (add zoom/wide handling to `ArticlePagerController`)

**Interfaces:**
- Consumes: `displayedPage`, `pageController` (Task 2).
- Produces: no new external surface; internal behavior only.

This reproduces today's behavior: when the current article's `WKWebView` can scroll horizontally (pinch-zoomed in, or content wider than the screen), a horizontal drag scrolls the article instead of flipping the page. Detection uses the web view's scroll-view `contentSize`, re-evaluated when a page settles and whenever that `contentSize` changes (which fires on load and on pinch-zoom).

- [ ] **Step 1: Add the paging-lock members to `ArticlePagerController`**

Add these members inside the `ArticlePagerController` class (e.g. after the `// MARK: - Pages` section):

```swift
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
```

- [ ] **Step 2: Call the re-evaluation hooks**

In `configure(...)`, after `pageController.setViewControllers([page], direction: .forward, animated: false)`, add:

```swift
            observeCurrentWebView()
            updatePagingForZoom()
```

In `update(...)`, after the programmatic `pageController.setViewControllers(...)` call, add:

```swift
        observeCurrentWebView()
        updatePagingForZoom()
```

In the `didFinishAnimating` delegate method, after `onIndexChange?(i)`, add:

```swift
        observeCurrentWebView()
        updatePagingForZoom()
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. If the compiler reports a concurrency error on `observeValue`/`deinit`, confirm `observeValue` is marked `nonisolated` and that the body uses `MainActor.assumeIsolated { ... }` (KVO and `removeObserver` are `NSObject` APIs and are not actor-isolated, so the `deinit` removal compiles).

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Manual verification in the simulator**

Find or open an article with content wider than the screen (e.g. a wide code block or table), or pinch-zoom an article in:
- While zoomed/wide: a horizontal drag scrolls the article content sideways and does **not** flip the page.
- Zoom back out (or scroll a normally-fitting article): horizontal swipe flips pages again.
- Normal (non-zoomed) articles page freely as before.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/ArticlePagerView.swift
git commit -m "feat: yield paging to horizontal web-view scroll when zoomed or wide"
```

---

## Task 4: Transparent reader toolbars

**Files:**
- Modify: `Yana/Views/ArticleReaderView.swift` (hide the top navigation bar background)
- Inspect: `Yana/Views/ArticleContentView.swift` (bottom action bar)

**Interfaces:**
- No code interfaces; SwiftUI modifier + visual change only.

- [ ] **Step 1: Hide the top navigation bar background**

In `Yana/Views/ArticleReaderView.swift`, add the toolbar-background modifier to the reader content so the nav bar floats over the article. Place it immediately after the `.toolbar { ... }` block (which closes at line 92) and before `.sheet(isPresented: $appState.showSettings)`:

```swift
            .toolbarBackground(.hidden, for: .navigationBar)
```

This is scoped to the reader's own `NavigationStack`. The config and filter screens are presented as `.sheet`s with their own navigation, so they are unaffected.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification — top bar**

Launch the app. Scroll an article up under the top bar:
- The nav bar (filter / star / gear) shows **no** material/opaque background — the article scrolls visibly beneath the floating buttons.
- Open Settings and the Filter sheet: their own navigation bars look normal (the transparency did **not** leak into them).

- [ ] **Step 4: Manual verification — bottom bar; fix only if a background is present**

Look at the bottom Open-in-Browser / Share bar over a scrolling article. The glass capsule buttons are expected to float (keep them). If there is **no** opaque/material strip behind them, no change is needed — skip to Step 5.

If an opaque background strip *is* visible behind the bottom buttons, remove it in `Yana/Views/ArticleContentView.swift` by making the bar an overlay so the web content extends beneath it, instead of a space-reserving inset. Replace:

```swift
            .safeAreaInset(edge: .bottom) { bottomBar }
```

with:

```swift
            .overlay(alignment: .bottom) { bottomBar }
```

Then rebuild (`xcodebuild ... build`) and re-check that the article content flows under the floating glass buttons with no opaque strip, and that the last lines of an article are still reachable by scrolling. If making it an overlay hides the final content, revert to `.safeAreaInset` (the inset background was not actually the problem) and leave the bottom bar as-is.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/ArticleReaderView.swift Yana/Views/ArticleContentView.swift
git commit -m "feat: float the reader toolbars over the article without a background"
```

---

## Self-Review Notes

- **Spec coverage:** native page scroll (Task 2), swipe-only / no nav buttons (Task 2 — none added), native default gap (Task 2 — `options: nil`), zoom/wide matches today (Task 3), transparent top + bottom bars (Task 4), pure index helper with unit test (Task 1), deletions of custom transition/gesture/shadow code (Task 2 — replaced wholesale). All spec sections map to a task.
- **Type consistency:** `TimelinePageIndex.index(of:in:) -> Int?` is defined in Task 1 and consumed in Task 2/3 (`displayedIndex(of:)`). `webScrollView(in:)`, `displayedPage`, `pageController`, `makePage(for:)` are all defined within `ArticlePagerController` and used consistently. `ArticlePage` and `ArticlePagerView` are unchanged.
- **No placeholders:** every code step shows complete code; the only conditional is Task 4 Step 4, which is a genuine runtime branch with explicit code and a revert path for both outcomes.
