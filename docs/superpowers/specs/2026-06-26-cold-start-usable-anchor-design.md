# Cold-Start: Fastest Fully-Usable Anchored Reader — Design

**Date:** 2026-06-26
**Status:** Approved (design); pending spec review → implementation plan

## Goal

Minimize the time from cold launch to a **fully-usable** anchored reader — visible,
scrollable, **and** swipeable to neighbors. Not a splash/placeholder: the real
`UIPageViewController`-based pager, interactive from first paint.

## Background / Measured Baseline

Measured on iPhone 17 simulator, 100 seeded articles, via the `StartupTrace`
instrumentation (subsystem `de.fa-krug.Yana`, category `startup`). Time to
`anchorVisible(adopted)` ≈ **970ms**, broken down:

| Window | Cost | Touchable by app code? |
|---|---|---|
| process + launch + `ModelContainer.init` (~87ms) + first frame | ~328ms | barely |
| warmup render + `SummaryIndexCache.load` → `ArticleStore.hasLoaded` | ~56ms | already fast |
| SwiftUI reacts → builds `ReaderHostView` → adopts warmed webview | ~125ms | **yes** |
| WebKit parse/layout/paint of anchor → `didFinish` → reveal | ~460ms | mostly no |

Confirmed empirically during investigation:
- The launch warmup adoption **works** (`warmupTake.HIT`); the webview is adopted
  while still `isLoading`, so reveal waits for `didFinish`.
- The dominant ~460ms is **genuine WebKit render time**. Ruled out as causes:
  process spawn (warming it saved only ~40ms), neighbor-prewarm contention
  (disabling prewarm changed nothing), and a missing key window (the window **is**
  present at warmup, so the webview is already on-window and laying out).
- **Swiping requires `ModelContainer`** (each neighbor page calls `resolveArticle`
  against the `ModelContext`), so a usable reader cannot skip `ModelContainer.init`.
  This is why disk-persisted anchor HTML was dropped from scope — its only unique
  payoff (paint before `ModelContainer`) is incompatible with "swipe must work."

**Caveat carried forward:** simulator WebKit is far slower than a device; the ~460ms
is likely 100–250ms on hardware. The levers below target the *touchable* costs (the
~125ms gating + a ~100–150ms earlier-load head start), not WebKit micro-tuning. A
device baseline should be captured to size the real win.

## Approach

Three coordinated changes; no new subsystems; the existing warmup→pager adoption
hand-off is preserved.

### Lever 1 — Earliest anchor load

Move `ReaderWarmup.start()` from `YanaApp`'s scene `.task` into
`AppDelegate.application(_:didFinishLaunchingWithOptions:)`, immediately after
`ModelContainer` is available (already forced there by `backgroundRefresh`). The
scene `.task` retains only `articleStore.start()`.

Front-loading the WebKit document load by ~100–150ms makes it more likely the load
has **finished** by the time the pager adopts the view, turning adoption into an
immediate reveal (`!isLoading`) instead of a wait-for-`didFinish`.

**Pre-window handling.** At `didFinishLaunching` there is usually no key window, so
the warmed webview cannot be parented on-screen. `ReaderWarmup` changes to:
- create the webview and call `loadHTMLString` immediately (the document load — the
  part that gates `didFinish` — progresses off-window);
- parent off-screen in the key window if one exists (as today); otherwise **park the
  webview and re-parent it into the key window on the next runloop** (a one-shot
  `DispatchQueue.main.async` that grabs `keyWindow()` once it exists), so paint
  completes against the real page width before adoption.

### Lever 2 — Reader-first bring-up (defer the full reconcile)

In `ArticleStore.bootstrap()`, after publishing the fast dataset (disk cache, else
the anchor-centered window) and flipping `hasLoaded`, **yield before `fullLoad()`**
(e.g. `await Task.yield()`), so SwiftUI builds the pager first and the full DB
reconcile runs without contending for the main thread during the critical reader
bring-up. `fullLoad` already self-heals the displayed position by identifier, so
deferring it is safe.

### Lever 3 — Single positioned build (tight gating)

In `ReaderScreen`, resolve the anchor index **as part of** computing
`filteredArticles`, so the first `.loaded` render already passes the anchor index to
`ReaderHostView` — eliminating the `onAppear`→`onChange` ping-pong and the
build-at-index-0-then-jump frame. The `didRestoreAnchor` gate is preserved exactly,
so user-navigation (`saveAnchor`) and `reanchorToCurrentArticle` semantics are
untouched.

## Components Touched

- `Yana/YanaApp.swift` (`AppDelegate`): kick `ReaderWarmup.start()` in
  `didFinishLaunching`; scene `.task` keeps `articleStore.start()`.
- `Yana/Reader/ReaderWarmup.swift`: support pre-window start (immediate load +
  deferred re-parent into the key window).
- `Yana/Services/ArticleStore.swift`: yield before `fullLoad()` in `bootstrap()`.
- `Yana/Reader/ReaderHostView.swift` (`ReaderScreen`): fold first-time anchor
  positioning into the filtered-list computation for a single positioned build.
- `Yana/Utilities/StartupTrace.swift` + reader markers: retained to verify wins and
  compare against a device baseline.

## Edge Cases (all already handled; preserved)

- Anchor filtered out of the current tag/feed filter → `discardUnused()` releases the
  warmed view; pager opens at the fallback index.
- Anchor deleted/missing → `ReaderWarmup.anchorArticle` falls back to the newest
  article.
- Empty library → `.empty` state unchanged.
- Theme / text-size mismatch between warmup and first page → HTML differs → clean
  warmup miss → cold render (status quo, no stale paint).

## Testing

- **Unit:** `ArticleStore.bootstrap` still publishes the fast dataset and flips
  `hasLoaded` before `fullLoad`; the yield does not drop the reconcile (existing
  `refreshNow` / save-sync tests stay green).
- **Unit:** anchor-index resolution yields the same index as today across the
  restore / reanchor / filtered-out cases.
- **Measured:** re-run the `StartupTrace` cold-start trace (100 seeded articles via
  `DebugSeed` / `YANA_SEED_ARTICLES`) before vs after; confirm `warmupTake.HIT` still
  fires and `anchorVisible(adopted)` moves earlier. Capture a device baseline.
- **Full suite:** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` green.

## Out of Scope

- Disk-persisted rendered anchor HTML (incompatible with the swipe requirement; see
  Background).
- WebKit render micro-tuning / theme-CSS slimming (separate effort; device-validate
  first).
- Any change to update/reload semantics, tag snapshotting, or the timeline model.
