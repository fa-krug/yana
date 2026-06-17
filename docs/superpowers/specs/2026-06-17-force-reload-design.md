# Force Reload for Feeds and Articles — Design

**Date:** 2026-06-17
**Status:** Approved (pending spec review)

## Summary

Add two new gesture-menu actions that bypass the normal incremental-update limits:

1. **Feed → "Force reload"** — re-fetch and refresh *every* article the source currently
   offers for that one feed, bypassing both the 60-day intake-window filter and the daily cap.
   The existing per-feed **"Update"** action stays exactly as-is (normal incremental update of
   just that feed).
2. **Article → "Force reload"** — a *true single-article re-fetch*: re-fetch that one article's
   content directly from its URL and overwrite the stored content. Falls back to a forced
   parent-feed reload for aggregator types that cannot re-fetch a lone URL.

In both cases the upsert continues to preserve `createdAt` (timeline position) and Starred state,
and (where the feed has AI enabled) AI post-processing is re-run on the refreshed content.

## Motivation

The existing **"Update"** action (`AggregationService.update(feed:)` /
`AggregationService.update(article:)`) only refreshes articles that are *still present in the
source's current fetch* **and** pass the 60-day intake-window date filter **and** survive the
daily cap. Consequences:

- An older stored article the source no longer lists, or one outside the intake window, is never
  refreshed.
- `update(article:)` does not target a single article at all — it re-runs the entire parent feed
  (with a `// Phase 4b refines this to a true single-article re-fetch.` TODO at
  `AggregationService.swift:168`), so an article outside the current window never refreshes even
  when the user swipes on *that* article.

Force reload closes both gaps.

## Current Behavior (reference)

`AggregationService.aggregate(feed:)` (`Yana/Services/AggregationService.swift:191-222`):

1. `aggregator.aggregate()` returns the source's current batch. The aggregator itself caps to
   `entries.prefix(max(config.dailyLimit, 1))` (`RSSPipelineAggregator.swift:26`).
2. Intake-window filter: `fetched.filter { AggregationLogic.isWithinIntakeWindow($0.date, now:) }`
   (line 208; default `maxAgeDays: 60`).
3. Daily cap: `AggregationLogic.runLimit(dailyLimit:collectedToday:)` → `prefix(cap)` (lines 209-210).
4. AI post-processing (line 211), then `ArticleUpsert.apply(...)` (line 212).

`ArticleUpsert.apply` (`Yana/Aggregators/ArticleUpsert.swift`) dedupes by `(feed, identifier)`:
existing identifiers update content and re-snapshot tags while preserving `createdAt` and Starred;
new identifiers insert with `createdAt = now`.

## Design

### 1. Service layer (`AggregationService` + `FeedConfig`)

- Thread a `force: Bool = false` parameter through the per-feed run: `aggregate(feed:force:)`.
  When `force == true`:
  - **Skip** the intake-window filter (use `fetched` directly instead of `fresh`).
  - **Skip** the daily cap (use `fetched.count` / no `prefix`).
  - Build `FeedConfig` with `dailyLimit` raised to `Int.max` so the aggregator's own internal
    `entries.prefix(dailyLimit)` does not truncate. Add a `force` flag (or a high `dailyLimit`)
    to `FeedConfig` for this. The `@MainActor init(feed:collectedToday:)` gains a
    `force: Bool = false` parameter that sets `dailyLimit = force ? .max : feed.dailyLimit`.
  - AI post-processing still runs on the (now unfiltered) batch.
- Add public `forceReload(feed:)` mirroring `update(feed:)`: sets `isUpdating`, calls
  `aggregate(feed:force:true)`, then `cleanupAndSave()`, returns the inserted count.
- Replace the placeholder `update(article:)` with a real `forceReload(article:)`:
  1. Resolve the article's parent `feed` (return 0 if none).
  2. Build a seed `AggregatedArticle` from the stored `Article`
     (`title`, `identifier`, `url`, `rawContent`, `content`, `date`, `author`, `iconURL`).
  3. Construct the aggregator via the registry and call `aggregator.refetch(seed)`.
  4. If it returns a refreshed `AggregatedArticle`: run AI post-processing on `[refreshed]`
     (consistent with the normal pipeline, using the feed's AI options), then
     `ArticleUpsert.apply([processed], to: feed, starredTag:, context:, now:)`.
  5. If it returns `nil` (aggregator can't re-fetch a single URL): fall back to
     `forceReload(feed:)`.
  - Wrap in the same `isUpdating` / `lastRunFailures` handling as the feed path.
- Keep the existing `update(feed:)` and `update(article:)`-equivalent normal behavior untouched
  for the "Update" buttons. (The article "Update" button continues to re-run the parent feed
  normally; only the new "Force reload" does the single-article re-fetch.)

### 2. Aggregator layer (single-article re-fetch)

- Add to the `Aggregator` protocol:
  ```swift
  /// Re-fetch a single, already-known article's content from its source.
  /// Returns nil when the aggregator cannot meaningfully re-fetch one item in isolation
  /// (caller then falls back to a forced full-feed reload).
  func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle?
  ```
  with a **default protocol-extension implementation returning `nil`**.
- Override `refetch` in `FullWebsiteAggregator` (inherited by `heise`, `merkur`, `tagesschau`,
  `caschysBlog`, `mactechnews`, `meinMmo`). It reuses the existing per-article content path:
  the `entry:` parameter of `enrich(_:entry:)` is unused throughout the `FullWebsiteAggregator`
  family, so `refetch` calls `enrich` on the seed with a synthesized/empty `FeedEntry` (or,
  cleaner, `enrich`'s `entry` becomes optional and `refetch` passes `nil`). This yields the real
  per-URL re-fetch with all existing selector / comment / multi-page / image-rewrite logic.
- The following keep the `nil` default (article force-reload falls back to a forced feed reload):
  - `feedContent` (`FeedContentAggregator`) — content lives in the RSS payload, not a separate page.
  - comic scrapers (`explosm`, `darkLegacy`, `oglaf`).
  - social/media sources (`reddit`, `youtube`, `podcast`).

### 3. UI layer

- **`FeedsView.swift`** leading swipe (around `:35`): add a second button **"Force reload"**
  (SF Symbol `arrow.trianglehead.2.clockwise`, a distinct tint, e.g. `.orange`) calling
  `forceReload(feed:)`. Keep the existing blue **"Update"** button unchanged. Disable while
  `isUpdating`.
- **`ArticleListView.swift`** leading swipe (around `:42`): add a **"Force reload"** button
  (same symbol/tint) calling `forceReload(article:)`, alongside the existing Star/Unstar (yellow)
  and **"Update"** (blue) buttons.
- Both reuse the existing `isUpdating` flag and the reader's top-right loading indicator. No new
  reader (`ArticleReaderView`) affordance — out of scope.

### 4. Localization

Add `"Force reload"` to `Yana/Resources/Localizable.xcstrings` with a German translation
following Apple's localization style (infinitive), e.g. `"Neu laden"`, marked
`"state" : "translated"`.

## Testing

Unit tests (`YanaTests/`, Swift Testing, `@MainActor`):

- **Feed force reload bypasses the intake window:** an article dated older than 60 days, returned
  by a stub aggregator, is imported under `forceReload(feed:)` but excluded under `update(feed:)`.
- **Feed force reload bypasses the daily cap:** with a small `dailyLimit` and a stub returning more
  items, `forceReload(feed:)` imports all of them.
- **`forceReload(article:)` overwrites content while preserving identity:** content/title refresh
  but `createdAt` and Starred are preserved for the matching identifier.
- **Unsupported aggregator fallback:** for an aggregator whose `refetch` returns `nil`,
  `forceReload(article:)` falls back to a forced feed reload (observable via the feed being
  re-aggregated).
- **`refetch` default returns nil:** the protocol default is `nil` unless overridden.

## Out of Scope

- A "Force reload all" toolbar action (only the per-feed and per-article gesture menus).
- Any force-reload affordance in `ArticleReaderView` (keeps its existing whole-timeline
  pull-to-refresh).
- Changing the existing "Update" actions' behavior.
