# Pre-rendered Anchor WebKit Warmup

**Date:** 2026-06-24
**Status:** Approved

## Problem

Cold-start load time is no longer bound by the data layer. The summary index loads
from disk in ~1–2ms (`SummaryIndexCache`), the SwiftData store is already fully open
by the time the reader runs (`AppDelegate.didFinishLaunchingWithOptions` accesses
`AppContainer.shared` and runs `ensureBuiltIns` + `save` synchronously before any UI),
and resolving the anchor `Article` is a single indexed `fetchByIdentifier`.

The dominant remaining cost on first paint is **WebKit**: when the first
`ReaderWebViewController` runs `viewDidLoad`, it creates a `WKWebView`, which spawns the
Web Content process, then `loadHTMLString` parses the document and builds the DOM before
the page fades in (~200–500ms). All of this happens *after* the reader appears, on the
post-appearance critical path.

## Goal

Move that WebKit work — process spawn + first-document parse — off the post-appearance
critical path by performing it during launch, before the reader's first page is created,
then handing the already-loaded web view to the first page.

Non-goals: changing the data/summary load path; deferring the eager store-open (the
store is already open at launch and that is acceptable); full off-screen *paint* warmup
(compositing completes on attach — see Edges).

## Design

### Launch kickoff

A new `@MainActor ReaderWarmup.start()` is kicked from the scene `.task` in `YanaApp`,
immediately before `articleStore.start()`:

```swift
.task { ReaderWarmup.shared.start(); articleStore.start() }
```

`start()` returns immediately after kicking off the async `WKWebView` load; it does not
await it. Starting here (rather than in `AppDelegate`) keeps launch return fast while
still preceding the whole bootstrap → layout → `makePage` pipeline, so the process spawn
has a head start over the work that leads to the first page being created.

### Anchor resolution + render

`ReaderWarmup.start()`:

1. Reads `AppSettings().timelineAnchorIdentifier`.
2. Resolves the `Article`:
   - If an identifier is present: `ArticleResolution.fetchByIdentifier(_:in:)` against
     `AppContainer.shared.mainContext` (store already open).
   - If nil: the newest article via a new `ArticleResolution.fetchNewest(in:)` helper
     (`FetchDescriptor<Article>` sorted by `createdAt` descending, `fetchLimit = 1`).
3. If no article resolves, does nothing (empty library / fresh install).
4. Renders `ArticleRenderer.fullPageHTML(article:theme:textSize:summaryPending:)` with
   `ArticleThemesManager.shared.currentTheme`, `AppSettings().articleTextSize`, and
   `summaryPending: false` (a stored anchor at cold start has no in-flight AI job).
5. Builds a `WKWebView` from the shared configuration factory (below), calls
   `loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)`, and parks
   `(identifier, html, webView)` in `ReaderWarmupStore.shared`.

The warmed web view has **no** navigation/UI delegate and **no** `linkClickedHandler`
message handler yet — only the link-interception userscript is injected. Delegates and
the message handler are wired when the page adopts it.

### Shared configuration factory

The `WKWebViewConfiguration` build currently inside `ReaderWebViewController.viewDidLoad`
(process pool, image scheme handler, user content controller + link-interception
userscript) is extracted into a small shared namespace, `ReaderWebView`, that owns the
shared `WKProcessPool` and `ImageSchemeHandler` (moved off `ReaderWebViewController`):

```swift
@MainActor
enum ReaderWebView {
    static let processPool = WKProcessPool()
    static let imageSchemeHandler = ImageSchemeHandler()

    /// Configuration with the shared process pool, image scheme handler, and the
    /// link-interception userscript. The per-page `linkClickedHandler` message handler
    /// is added by the page itself (it is weakly tied to the view controller).
    static func makeConfiguration() -> WKWebViewConfiguration { ... }
}
```

Both `ReaderWebViewController` and `ReaderWarmup` build their web views through this
factory so the warmed view is byte-for-byte adoptable by the page.

### Handoff slot

`ReaderWarmupStore` is a `@MainActor` single-slot holder. Its match/keying logic is a
pure generic value type so it is unit-testable without a `WKWebView`:

```swift
struct WarmupSlot<Payload> {
    let identifier: String
    let html: String
    let payload: Payload

    /// Returns the payload iff both the identifier and the rendered HTML match.
    func matched(identifier: String, html: String) -> Payload? {
        (self.identifier == identifier && self.html == html) ? payload : nil
    }
}

@MainActor
final class ReaderWarmupStore {
    static let shared = ReaderWarmupStore()
    private var slot: WarmupSlot<WKWebView>?

    func store(identifier: String, html: String, webView: WKWebView) { ... }

    /// Single-use: returns the warmed web view on a match and clears the slot;
    /// returns nil otherwise (slot retained for a later attempt).
    func take(identifier: String, html: String) -> WKWebView? { ... }

    /// Release any remaining warmed view (the warm went unused).
    func discardUnused() { ... }
}
```

HTML-string equality is the validity gate: any difference in theme, text size, or
summary state produces a different string and therefore a clean miss — no stale render.

### Adoption in `ReaderWebViewController`

`viewDidLoad` is restructured so the web view is obtained one of two ways:

1. Compute the page's HTML once (the same `ArticleRenderer.fullPageHTML(...)` call
   `render()` makes).
2. `ReaderWarmupStore.shared.take(identifier: article.identifier, html: computedHTML)`:
   - **Hit:** adopt the warmed web view — assign `self.webView`, add the
     `linkClickedHandler` message handler to the existing
     `webView.configuration.userContentController`, set `navigationDelegate`/`uiDelegate`
     to `self`, add to the view hierarchy with the existing constraints, set
     `loadedHTML = computedHTML` so `render()` is a no-op, and set opacity: if
     `!webView.isLoading`, fade to `alpha = 1` immediately; otherwise leave `alpha = 0`
     and let `didFinish` fade it in.
   - **Miss:** current path — build a fresh web view via `ReaderWebView.makeConfiguration()`,
     wire it, and call `render()`.

The rest of `viewDidLoad` (tap zones, appearance-change observers) is unchanged. The
existing `webViewWebContentProcessDidTerminate` → `render(force:)` recovery is unaffected.

### Discarding an unused warm

After `ReaderArticleViewController.configure(articles:index:)` sets the first page, it
calls `ReaderWarmupStore.shared.discardUnused()` so a warmed view that no page adopted
(e.g. the saved anchor was filtered out of the current tag filter and a different article
opened first) is released rather than lingering for the session.

## Edges

- **Anchor filtered out / changed between launches:** the first page's HTML won't match
  the warmed HTML → clean miss → normal fresh render; warmed view discarded. Correctness
  unaffected, only a wasted warm.
- **Off-window warm:** a `WKWebView` not in a window may defer final tiling/compositing.
  Process spawn, document parse, and userscript injection — the bulk of the cost — still
  happen during launch; compositing completes quickly on attach. Full off-screen paint
  (parenting the warmed view into a zero-rect container in the key window) is a possible
  follow-up, not v1.
- **Empty library / fresh install:** no anchor and no newest article → warmup is a no-op.
- **summaryPending mismatch:** if the first page is rendered with `summaryPending: true`
  (rare for a cold-start anchor), its HTML differs → clean miss → normal render.

## Testing

Swift Testing (`import Testing`), `@MainActor`.

- `WarmupSlot` match logic: returns payload on identifier+HTML match; nil when the
  identifier differs; nil when the HTML differs.
- `ReaderWarmupStore`: `take` returns the stored view on a match and clears the slot
  (second `take` returns nil); `take` on a mismatch retains the slot; `discardUnused`
  clears it. Uses a `WarmupSlot<String>`-level test for the pure logic; the store test
  may use a lightweight stand-in payload to avoid instantiating `WKWebView`.
- Anchor resolution against an in-memory `ModelContainer` (per `TestHelper`): a saved
  identifier resolves to that article; a nil identifier resolves to the newest by
  `createdAt`; rendered HTML is non-empty.

`WKWebView` adoption itself (delegate wiring, fade-in, message handler) is verified by
build + manual run, not unit tests.

## Files

- **New** `Yana/Reader/ReaderWarmup.swift` — `ReaderWarmup`, `ReaderWarmupStore`,
  `WarmupSlot`.
- **New** `Yana/Reader/ReaderWebView.swift` (or co-located) — shared configuration
  factory + shared `processPool`/`imageSchemeHandler`.
- **Edit** `Yana/Reader/ReaderWebViewController.swift` — use the factory; adopt a warmed
  web view in `viewDidLoad`.
- **Edit** `Yana/Reader/ReaderArticleViewController.swift` — `discardUnused()` after the
  first page is configured.
- **Edit** `Yana/YanaApp.swift` — kick `ReaderWarmup.shared.start()` from the scene
  `.task`.
- **Edit** `Yana/Services/ArticleResolution.swift` — add `fetchNewest(in:)`.
- **New** `YanaTests/ReaderWarmupTests.swift`.

No user-facing strings; no localization changes.
