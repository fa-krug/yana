# Faster Cold Start: Summary-Index Cache + Anchor-Centered Window

**Date:** 2026-06-24
**Status:** Approved (design)

## Problem

On cold start the reader (the home surface) shows nothing until `ArticleStore`
finishes loading the **entire** library's lightweight index off the main thread:

```
start() → ArticleSummaryLoader.load()  // fetch ALL Article rows,
                                        // propertiesToFetch + feed/tags prefetch,
                                        // map each to ArticleSummary
        → summaries published, hasLoaded = true
        → reader resolves the anchor index and builds the first page
```

For a medium library (≈300–1500 articles) that full fetch — dominated by the
per-row `feed` / `tags` relationship traversal — gates first paint even though the
reader only needs the anchor article plus a few neighbors to become interactive.

### What is *not* the gate

The SwiftData `ModelContainer` is created **synchronously in
`AppDelegate.didFinishLaunching`** (to bootstrap built-in tags), before any reader
UI exists. So by the time the pager builds its first page the store is already open,
and resolving an `Article` by `persistentID` is a cheap lookup. Container open and
per-page render (CSS is already memoized in `ArticleRenderer.cssCache`) are therefore
**not** cold-start gates, and an investigation confirmed a rendered-HTML cache would
buy only ~one row-read plus a cheap macro render — not worth the regression risk of
threading an optional `Article` through the pager. The only real gate is getting
`summaries` populated.

## Goal

Make `summaries` available — and the reader interactive at the saved anchor — as
fast as possible on cold start, without changing the in-sync-with-saves model, the
filter pipeline, or the anchor save/restore/reanchor logic.

## Design

Two composing fast-paths feed `ArticleStore.summaries`, plus the existing full DB
load as the authoritative reconciliation.

### Layer 1 — `SummaryIndexCache` (disk persistence of the index)

New `Yana/Services/SummaryIndexCache.swift`.

- Persists the published `[ArticleSummary]` to a single file in the **Caches**
  directory (semantically a derived cache; if the OS purges it, Layer 2 covers the
  next launch).
- `ArticleSummary` gains `Codable` conformance. `PersistentIdentifier` is `Codable`;
  `Date` / `Set<String>` / `String` already are.
- API (file IO runs **off the main actor** so the read/decode never blocks main):
  - `func load() async -> [ArticleSummary]?` — returns `nil` when absent or on any
    decode error (corruption / format change → silent fallback, never a crash).
  - `func save(_ summaries: [ArticleSummary]) async` — encodes and writes atomically.
- Encoding: `PropertyListEncoder` (binary) or `JSONEncoder`; either decodes a
  1500-element array of small structs in single-digit ms.

### Layer 2 — Anchor-centered window (small first DB fetch)

`ArticleSummaryLoader` gains a windowed fetch used **only on a cache-cold launch**:

```
func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary]
```

- With an anchor: fetch the anchor row by `identifier` (1 row) for its `createdAt`,
  then two bounded fetches sharing `load()`'s `propertiesToFetch` +
  `feed` / `tags` prefetch:
  - **newer-or-equal:** `#Predicate { $0.createdAt >= anchorDate }`, ascending,
    `fetchLimit = radius + 1` (includes the anchor itself).
  - **older:** `#Predicate { $0.createdAt < anchorDate }`, descending,
    `fetchLimit = radius`; reversed to ascending.
  - Concatenate `older.reversed() + newerOrEqual` → ascending window centered on the
    anchor. (`createdAt` ties are harmless: the authoritative full load and
    reanchor-by-`identifier` correct any transient neighbor-order difference.)
- Without an anchor, or when the anchor row is not found: newest `2·radius + 1` via
  reverse-sort + `fetchLimit`, reversed to ascending (covers a brand-new library).
- `radius` constant ≈ 25 (≈51-article window) — generous enough that the anchor's
  immediate neighbors are present for the first swipes.

### Data flow — `ArticleStore.start()`

`start()` stays synchronous (registers the `didSave` observer as today) and kicks a
bootstrap task:

```
start():
  register didSave observer            // unchanged
  Task { await bootstrap() }

bootstrap():
  if let cached = await SummaryIndexCache.load():   // WARM launch
      summaries = cached; hasLoaded = true          // instant first paint
      await fullLoad()                              // reconcile to live rows
  else:                                             // COLD cache (first launch / purged)
      let window = try? await loader.loadWindow(around: anchorID, radius: 25)
      summaries = window ?? []; hasLoaded = true     // fast first paint
      await fullLoad()                              // grow to the full set

fullLoad():
  let all = (try? await loader.load()) ?? []
  summaries = all
  await SummaryIndexCache.save(all)

// anchorID = AppSettings().timelineAnchorIdentifier
```

`refreshNow()` (the existing `didSave`-driven path) is unchanged except it also
writes the cache after publishing, so the cache tracks every mutation.

**Republish transitions.** A cold launch publishes the window (small) then the full
load — pure growth. A warm launch publishes the cache then the full load — usually
the same set; the one case where the full load is *smaller* is when retention
deleted articles since the last cache write, so a few stale rows briefly appear and
then vanish. That is harmless: the existing `onChange(of: store.summaries)` →
`recomputeFilter()` + `reanchorToCurrentArticle()` re-resolves the anchor by
`identifier` across each republish (and falls back to the newest item if the anchor
was one of the deleted rows), so `currentIndex` stays coherent. The stale-`persistentID`
safety net below also covers any deleted row that lingers for a frame.

### Stale `persistentID` safety net

A cached `persistentID` can go stale across a store migration/reinstall. Today
`resolveArticle` is `modelContext.model(for: persistentID) as? Article`. Harden it to
fall back to a one-row fetch by `identifier` when `model(for:)` returns `nil`, so a
stale cached ID never yields a blank page (the background full load also republishes
fresh IDs within ms). The fallback fetch runs only on the miss path.

## Components & boundaries

- **`SummaryIndexCache`** — pure disk read/write of `[ArticleSummary]`. No SwiftData,
  no UI. Testable in isolation (round-trip, absent-file, corrupt-file).
- **`ArticleSummaryLoader.loadWindow`** — pure SwiftData fetch returning `Sendable`
  summaries; testable with a seeded in-memory container.
- **`ArticleStore`** — orchestrates cache → window → full; the only stateful piece.
- **`ReaderHostView.resolveArticle`** — gains the identifier fallback; otherwise
  unchanged.

No changes to `ReaderArticleViewController` / `ReaderWebViewController`, the filter
pipeline, anchor logic, retention, aggregation, or background refresh.

## Testing

- `SummaryIndexCache`: save→load round-trip preserves all fields; `load()` returns
  `nil` for absent and for corrupt data.
- `ArticleSummary` `Codable` round-trip (incl. `PersistentIdentifier`, `tagNames`,
  `isStarred`, `feedLogoHash`).
- `loadWindow(around:radius:)`: returns an anchor-centered slice that includes the
  anchor; falls back to the newest `2·radius+1` when the anchor is `nil` / missing;
  respects `radius` bounds.
- `ArticleStore`: with a pre-seeded cache, `bootstrap()` publishes the cached
  summaries and flips `hasLoaded` before the DB load, then reconciles to the DB set;
  with no cache, it publishes the window then the full set (never shrinks).
- Existing `ArticleStoreTests` / anchor / filter tests continue to pass.

## Trade-offs / risks

- **Two-to-three `summaries` publishes at launch** (cache|window → full). Each runs
  `recomputeFilter` + reanchor; both are O(n) over light structs and already run on
  every `didSave`. Acceptable.
- **Caches purge** drops Layer 1; Layer 2 keeps that launch fast. By design.
- **`propertiesToFetch` reliance** is unchanged from the current loader; if an OS
  build ignores it, correctness is unaffected (heavy fields simply load).
- **`PersistentIdentifier` Codable format** is an Apple-owned encoding; if it changes
  across OS versions a decode fails → `load()` returns `nil` → clean fallback to the
  DB path. No crash, only a slower launch that self-heals on the next save.

## Out of scope

- Rendered-HTML caching / paint-before-DB (investigated; not worth the pager risk for
  the marginal gain — see "What is not the gate").
- Reader browsing performance, aggregation, retention, background-refresh changes.
- Speeding up the synchronous container open in `didFinishLaunching`.
