# Felt-Performance & Loading-State UX — Design

**Date:** 2026-06-19
**Status:** Approved design, pending spec review

## Goal

Improve the app's *felt* performance: reduce real loading times where it's cheap and
safe, and mask the rest with native-feeling loading states, cross-fades, and progress
feedback. The user's directive: "look everywhere." Visual sensibility: **native &
invisible** — lean on iOS conventions (redaction/skeletons, subtle cross-fades, system
indicators) so the masking is barely noticeable rather than branded/expressive.

Scope explicitly includes **genuine latency reduction** alongside the masking layer
(prefetch, page reuse, non-blocking launch perception), not just loading-state UI.

## Approach

Approach A (chosen): **Foundation-first, then one workstream per surface.** Build a small
set of shared primitives once, then apply them across each surface as an independent task.
Surface tasks are independent enough to run via subagent-driven development.

Constraint: **no third-party dependencies** — native SwiftUI/UIKit/WebKit only, matching
the existing architecture.

## Current-state findings (grounding)

- **Reader pager** (`ReaderArticleViewController`) recreates and re-renders a
  `ReaderWebViewController` on every `makePage(for:)` call — even revisiting a just-read
  article re-runs `loadHTMLString`. `ReaderWebViewController.render()` already early-returns
  when the rendered HTML is unchanged, so the waste is lifecycle/ownership, not rendering.
- **No `WKNavigationDelegate.didFinish` handling** — nothing knows when a page is actually
  ready, so there's no point to fade in from or to gate on. The web view's
  `backgroundColor` is `.systemBackground`, which can flash before the themed article
  background paints.
- **Updates already insert incrementally** — each feed upserts as its task finishes and the
  timeline `@Query` refreshes live, so new articles arrive *during* a run. The bare spinner
  hides progress that is already happening.
- **Images are served from a local disk cache** via the `yana-img://<hash>` scheme
  (`ImageSchemeHandler` → `ImageStore`), already downloaded at aggregation time. In-reader
  image latency is disk-read, not network.
- **Launch empty-state flash**: `filteredArticles` starts `[]` and is computed in
  `onAppear`, so `ContentUnavailableView` ("No Articles") can flash before content even when
  the database is full.

---

## Section 1 — Foundation primitives

Built once, consumed by every surface below.

### 1.1 Skeleton / redaction modifier
A native placeholder treatment: SwiftUI's built-in `.redacted(reason: .placeholder)` plus a
subtle, slow opacity pulse. **No custom shimmer gradient** — keep it native & invisible.
Exposed as `.skeleton(active: Bool)` (a `ViewModifier`). Consumed by the launch timeline
(Section 3) and identifier search rows (Section 6).

### 1.2 Cross-fade helper
A single shared definition of the fade duration/curve (~0.2s ease) used wherever content
swaps loading→loaded so nothing "pops":
- SwiftUI surfaces: a shared `.transition`/`withAnimation` constant.
- UIKit reader: `UIView.transition` with `.transitionCrossDissolve` at the same duration.

One source of truth for the timing so every surface feels consistent.

### 1.3 Progress reporting on `AggregationService`
Add an observable progress channel, additive only — no change to aggregation behavior:
- `var updateProgress: (completed: Int, total: Int)?` — `nil` when idle.
- `updateAll()` sets `total` to the enabled-feed count up front, increments `completed`
  as each feed's task finishes in the existing bounded task group, and resets to `nil` on
  completion (alongside the existing `isUpdating` reset).
- Single-feed / single-article operations (`update(feed:)`, `forceReload(feed:)`,
  `forceReload(article:)`, `summarize`) leave `updateProgress` `nil` — they keep the
  existing indeterminate spinner.

Consumed by the update-feedback surface (Section 4).

---

## Section 2 — Reader (highest-traffic surface)

Three changes in `ReaderArticleViewController` / `ReaderWebViewController`.

### 2.1 Cache & reuse page controllers
`ReaderArticleViewController` keeps a bounded **LRU cache of `ReaderWebViewController`
instances keyed by article identifier**. `makePage(for:)` returns a cached instance when
present instead of constructing a fresh one. Revisiting a recently-seen article is then
instant (no re-render; `render()`'s unchanged-HTML guard makes a reused instance a no-op).

- **Cache capacity: ~25 controllers** (named constant). Sized to hold the full ±5 prewarm
  window on *both* sides plus a little recent history.
- LRU eviction tears down off-window web views so memory stays bounded.

### 2.2 Fade in on actual load completion
`ReaderWebViewController` becomes its own `WKNavigationDelegate` `didFinish` observer:
- The web view starts at `alpha 0` over the **themed background color** (sourced from the
  current `.nnwtheme` via `ArticleThemesManager` / theme CSS, not `.systemBackground`), so
  there is no white/system flash and no lingering previous article.
- On `didFinish`, cross-fade the web view in (Section 1.2 timing).
- No spinner — the masking is the correct-colored background + fade ("invisible").

### 2.3 Prewarm a wide window for burst swiping
On page settle (`didFinishAnimating`) **and** re-triggered as a swipe begins (not only after
it completes), proactively instantiate the **±5** neighbor controllers, which kicks off their
`loadHTMLString` in the background. A rapid burst of up to 5 swipes in either direction then
lands on already-rendered HTML the whole way.

- **Prewarm radius: ±5** (named constant).
- **Directional bias:** when the user is flicking forward, the +5-ahead neighbors warm
  before the behind ones (and vice-versa), so the common one-direction burst is fully warm
  first.

### 2.4 Memory discipline (the ±5 / ~25 tradeoff, handled honestly)
25 live `WKWebView`s is real memory. These are simple static-HTML views (no network, no
heavy JS), so each is modest, but it adds up. Mitigations:
- Cache size and prewarm radius are **named constants**, profiled and tuned on-device; they
  dial back without code changes if profiling shows pressure.
- **On `UIApplication.didReceiveMemoryWarningNotification`**, trim the cache to the live
  window (drop off-window controllers / their web views).
- LRU eviction enforces the hard ceiling regardless of navigation pattern.

Result: forward and backward bursts up to ~5 swipes are delay-free, with bounded memory.

---

## Section 3 — App launch

**Eliminate the empty-state flash.** Introduce a three-state distinction in `ReaderScreen`:
- **loading** — the timeline `@Query` has not yet delivered, or the first filter recompute
  has not run.
- **empty** — delivered and genuinely zero articles.
- **loaded** — articles present.

While **loading**, render a **skeleton timeline** (Section 1.1) — redacted article-shaped
placeholder rows — instead of either the blank or the "No Articles" view. The real
`ContentUnavailableView` shows only once we know the database is actually empty. This removes
the blank→content pop on cold start.

Implementation note: distinguish "query not yet delivered" from "delivered empty". Track a
flag set on the first `@Query` delivery / first `recomputeFilter()` so the empty state is
gated behind a confirmed-empty result, not merely an as-yet-uncomputed `filteredArticles`.

---

## Section 4 — Update feedback

**Surface the progress that already happens.** Using Section 1.3's `updateProgress`:
- During `updateAll()`, replace the bare nav-bar spinner with a **determinate indicator +
  count** ("Updating 3 of 8…"). Because feeds upsert incrementally and the timeline `@Query`
  refreshes live, the user sees new articles arriving while the count climbs — a dead wait
  becomes visible progress.
- Single-feed / single-article reloads keep the existing **indeterminate** spinner (fast, no
  meaningful N).
- The existing completion toast (`RefreshOutcome.message`) stays.

The progress UI lives where the current spinner does (the reader nav bar, via
`ReaderArticleViewController.setRefreshing` extended to accept optional progress), driven by
`UpdateActivity` / `AggregationService.updateProgress`.

---

## Section 5 — AI summarize

**Make it visibly in-progress, then settle.** Today the summary is injected silently and the
page re-renders.
- When summarize starts, inject a **redacted placeholder summary block** at the exact spot
  the real summary will occupy (between the lead image and the article text), using the
  skeleton treatment.
- When the summary returns, **cross-fade** the real text in place of the placeholder.
- On failure, remove the placeholder and show the existing "Summarize Failed" alert.

This is driven through the existing `isSummarizing` flag + `reloadToken` re-render path; the
renderer (`ArticleRenderer`) gains a "summary pending" rendering state so the placeholder is
part of the HTML it produces.

---

## Section 6 — Search & OPML (lighter)

### 6.1 Identifier search (`IdentifierSearchView`)
- While `isSearching`, show **skeleton result rows** (Section 1.1) instead of an empty/stale
  list.
- **Debounce** keystrokes so each character doesn't fire an immediate request.
- Results **cross-fade** in.

### 6.2 OPML import
- For large files, show an **in-progress indicator** ("Importing N feeds…") rather than only
  the completion alert.
- If the parse is fast enough in practice, this degrades gracefully to the existing alert —
  implementation confirms whether a progress count is worth it or a determinate spinner
  suffices.

---

## Testing strategy

- **Section 1.3 (progress reporting):** unit-test that `updateAll()` drives
  `updateProgress` from `(0, N)` to `(N, N)` and resets to `nil`, using the existing
  injectable `AggregationService` test seams (mock aggregator factory).
- **Section 2 (cache/LRU/prewarm):** unit-test the LRU cache eviction (capacity bound,
  most-recently-used retention) and the prewarm window/direction computation as pure logic
  extracted from the view controller (so it's testable without a live `WKWebView`).
- **Section 3 (launch states):** unit-test the loading/empty/loaded state derivation as a
  pure function of (query-delivered flag, article count).
- **Section 6.1 (debounce):** unit-test the debounce/coalescing logic if extracted as pure
  logic; otherwise covered by manual/UI verification.
- **Visual behavior** (fades, skeleton appearance, memory-warning trim): manual verification
  on-device/simulator — these are presentation concerns without meaningful unit assertions.

## Localization

Every new user-facing string (e.g. "Updating %d of %d…", "Importing %d feeds…", any
summarize-pending label) must be added to `Localizable.xcstrings` with a `de` translation
marked `"state": "translated"`, per project convention (Apple localization style, infinitive
for actions, no Du/Sie).

## Out of scope (this pass)

- Branded/expressive animation language (chosen: native & invisible).
- Content-image prefetching beyond what aggregation already caches.
- Restructuring the `@Query`/SwiftData fetch into an async/background load (the launch fix is
  perceptual — skeleton + confirmed-empty gating — not a fetch-architecture change).
- Credential-test loading states (already adequate).

## Workstream independence (for subagent-driven execution)

1. **Foundation** (Section 1) — must land first; everything depends on it.
2. **Reader** (Section 2) — independent after Foundation.
3. **Launch** (Section 3) — independent after Foundation (skeleton modifier).
4. **Update feedback** (Section 4) — depends on Foundation 1.3.
5. **AI summarize** (Section 5) — independent after Foundation.
6. **Search & OPML** (Section 6) — independent after Foundation.

Sections 2–6 can run in parallel once Foundation is merged.
