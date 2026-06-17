# Native Page Navigation for the Article Timeline

**Date:** 2026-06-17
**Status:** Approved — ready for implementation plan

## Summary

Replace the reader's hand-rolled push/pop transition with the native paging control
NetNewsWire uses for its article detail: a `UIPageViewController` configured with
`.scroll` transition style and `.horizontal` navigation orientation. Articles slide
edge-to-edge with the system's own smooth, interruptible, rubber-banding paging
animation. Navigation stays swipe-only (no toolbar prev/next buttons). As part of the
same immersive-reader pass, the top navigation bar and bottom action bar should not
paint a background over the article.

## Motivation

The current `ArticlePagerView` is a custom `UIViewController` that hand-rolls a
navigation-controller-style push/pop: the next article slides *over* the current one
with parallax and a leading shadow, the previous is revealed underneath, all driven by
`CGAffineTransform` + `UIView.animate` and a custom pan recognizer. NetNewsWire instead
uses a stock `UIPageViewController(.scroll, .horizontal)`, where pages slide
side-by-side edge-to-edge — the most native, smooth iOS paging feel (identical to Apple
Mail / News). The goal is to adopt that native control and animation.

## Decisions (from brainstorming)

- **Transition feel:** native page scroll via `UIPageViewController(.scroll)` — *not*
  the current parallax push/pop.
- **Navigation buttons:** swipe only. No toolbar prev/next/next-unread buttons (Yana has
  no read/unread state).
- **Inter-page gap:** keep the native default gap (the thin gutter visible mid-swipe in
  Mail/News). No suppression.
- **Zoom/wide handling:** match today's behavior — when the article's web view can scroll
  horizontally (zoomed in or content wider than the screen), a horizontal drag scrolls
  the article instead of flipping the page; paging re-enables once the content fits again.
- **Toolbars:** the top nav bar and bottom action bar must not render a background over
  the article.

## Scope

In scope:
- Rewrite of `ArticlePagerController` (in `Yana/Views/ArticlePagerView.swift`) around a
  child `UIPageViewController`.
- A small pure helper for the article → index lookup, with a unit test.
- Transparent top navigation bar in `ArticleReaderView`.
- Verifying the `ArticleContentView` bottom bar shows no bar background.
- Deleting the now-dead custom-transition code.

Out of scope:
- Any change to `ArticlePagerView`'s public API or to `ArticleReaderView`'s pager usage,
  anchor persistence, filtering, or refresh logic.
- Toolbar buttons, read/unread state, the config hub, search detail screen.

## Public surface (unchanged)

`ArticlePagerView: UIViewControllerRepresentable` keeps its exact current signature so
`ArticleReaderView` needs no changes to its pager call site:

```swift
struct ArticlePagerView: UIViewControllerRepresentable {
    let articles: [Article]
    @Binding var currentIndex: Int
    var onRefresh: (() -> Void)?
}
```

Each page remains an `ArticlePage` — a `UIHostingController<ArticleContentView>` that
remembers its `Article` (used to map a displayed page back to a timeline index). Per-page
pull-to-refresh, the bottom action bar, web-view vertical scrolling, and pinch-to-zoom are
all untouched; they live below the page level and are unaffected by how pages are paged.

## Design

### `ArticlePagerController` (rewrite)

Owns a child `UIPageViewController`:

```swift
let pageController = UIPageViewController(
    transitionStyle: .scroll,
    navigationOrientation: .horizontal,
    options: nil // native default inter-page gap
)
```

Added as a child view controller filling `view.bounds`; the controller is its
`dataSource` and `delegate`.

State carried by the controller:
- `articles: [Article]`
- `index: Int` — the timeline index of the currently displayed page
- `onRefresh: (() -> Void)?`
- `onIndexChange: ((Int) -> Void)?`

#### Page construction

```swift
private func makePage(for index: Int) -> ArticlePage? {
    guard articles.indices.contains(index) else { return nil }
    return ArticlePage(article: articles[index], onRefresh: onRefresh)
}
```

#### Data source — endless timeline economy

Given the page the user is looking at, find its article's index by `identifier`, then vend
the neighbor (or `nil` at the ends):

```swift
func pageViewController(_ pvc, viewControllerBefore vc) -> UIViewController? {
    guard let i = displayedIndex(of: vc), i > 0 else { return nil }
    return makePage(for: i - 1)
}
func pageViewController(_ pvc, viewControllerAfter vc) -> UIViewController? {
    guard let i = displayedIndex(of: vc), i < articles.count - 1 else { return nil }
    return makePage(for: i + 1)
}
```

`displayedIndex(of:)` resolves an `ArticlePage`'s article to its current timeline index
via the pure helper below. Because `UIPageViewController` only requests the neighbor it is
sliding toward and discards pages it scrolls away from, an endless timeline never
instantiates a web view per article — only the visible page plus the transient neighbor
are alive, preserving today's memory behavior.

#### Pure index-lookup helper (unit-tested)

Extract the article → index resolution so it is testable without UIKit:

```swift
enum TimelinePageIndex {
    /// Index of the article with `identifier` in `articles`, or nil if absent.
    static func index(of identifier: String?, in articles: [Article]) -> Int?
}
```

Used by both `displayedIndex(of:)` and `update(...)`.

#### Index binding

On a completed swipe, publish the new index up to the binding (which drives anchor
persistence in `ArticleReaderView`, unchanged):

```swift
func pageViewController(_ pvc, didFinishAnimating finished, previousViewControllers,
                        transitionCompleted completed) {
    guard completed,
          let page = pageController.viewControllers?.first as? ArticlePage,
          let i = displayedIndex(of: page) else { return }
    index = i
    onIndexChange?(i)
    updatePagingForZoom() // re-evaluate horizontal-scroll lock for the new page
}
```

#### Initial display & programmatic swaps

`configure(...)` sets the first page with `setViewControllers([page], direction: .forward,
animated: false)`.

`update(articles:index:onRefresh:)` mirrors today's `swapCurrent` semantics:
- Store the new `articles` / `onRefresh`.
- Never reshuffle mid-swipe — guard while a transition is in progress (tracked via
  `didFinishAnimating` / a `delegate willTransitionTo` flag).
- If the displayed page's article identifier already equals the target index's article
  identifier, do nothing (e.g. the swipe itself produced this index).
- Otherwise replace instantly: `setViewControllers([makePage(for: index)], animated: false)`.
  This covers restoring the saved anchor and clamping after a filter change.

### Zoom / wide-content handling

Reuse the existing static `webScrollView(in:)` finder. When the current page's `WKWebView`
scroll view satisfies `contentSize.width > bounds.width + 1`, the article can scroll
horizontally, so paging must yield:

- Find the `UIPageViewController`'s internal `UIScrollView` (the scroll-style pager exposes
  one in its view hierarchy) and toggle `isScrollEnabled`:
  - `false` when the current web view scrolls horizontally → horizontal drags scroll the
    article.
  - `true` otherwise → horizontal drags page.
- Re-evaluate (`updatePagingForZoom()`) when a page settles (`didFinishAnimating`) and on
  web-view zoom/content-size changes (observe the web scroll view's `zoomScale` /
  `contentSize`, or its `delegate`/KVO — the simplest reliable hook that fires on
  pinch-zoom).

This reproduces today's "don't flip a zoomed/wide article" behavior with the native pager.

### Transparent toolbars (immersive reader)

The article web view already renders edge-to-edge; the bars must not paint a background
over it.

- **Top:** in `ArticleReaderView`, add `.toolbarBackground(.hidden, for: .navigationBar)`
  so the nav bar (filter / star / gear) floats over the article with no material backing.
  Scope this to the reader's own `NavigationStack` so it does not leak into presented
  config / settings screens (those are `.sheet`s with their own navigation, so this is
  naturally contained — verify during implementation).
- **Bottom:** verify `ArticleContentView`'s bottom action bar (the `GlassEffectContainer`
  of glass capsule buttons inside `.safeAreaInset(edge: .bottom)`) renders no opaque or
  material gutter behind the buttons. The glass capsules themselves stay (they are meant
  to float); only an unwanted bar background, if any, is removed.

### Deletions

Remove the now-dead custom-transition machinery from `ArticlePagerView.swift`:
- `HorizontalPanGestureRecognizer` (whole class).
- The `parallax` constant.
- `applyShadow(to:)` / `clearShadow(from:)`.
- `beginTransition`, `progress`, `apply(progress:...)`, `finish(gesture:...)`, `handlePan`,
  and the manual `CGAffineTransform` math.
- The `direction` / `incoming` / `isFinishing` push/pop bookkeeping (replaced by the
  page-controller transition flag).

Kept: `ArticlePage`, `makePage`, the `webScrollView(in:)` finder, and the
`UIGestureRecognizerDelegate` simultaneous-recognition allowance only if still needed (the
page controller manages its own gestures, so this likely also goes — confirm during
implementation).

## Testing

- **Unit test** the pure `TimelinePageIndex.index(of:in:)` helper: present identifier →
  correct index; absent / nil identifier → nil; empty list → nil.
- The transition itself is UIKit/gesture-driven and not meaningfully unit-testable; rely on
  manual simulator verification for:
  - Smooth native edge-to-edge paging both directions.
  - Index binding still updates the anchor (position remembered across launches).
  - Filter change / refresh re-anchors without animation and without mid-swipe glitches.
  - Zoomed/wide article: horizontal drag scrolls the article, not the page; paging resumes
    when zoomed back out.
  - Top nav bar and bottom action bar show no background over the article; config/settings
    sheets are unaffected.

## Risks / notes

- Reaching into `UIPageViewController`'s private internal `UIScrollView` to toggle
  `isScrollEnabled` is a documented-by-convention technique (widely used) but relies on the
  view hierarchy shape. Find it defensively (search subviews for the first `UIScrollView`)
  and no-op if absent, so a future iOS change degrades to "always pages" rather than
  crashing.
- `.scroll`-style `UIPageViewController` with `WKWebView` children generally coexists fine
  because each web view owns vertical scroll; horizontal conflicts are handled by the
  zoom/wide toggle above.
