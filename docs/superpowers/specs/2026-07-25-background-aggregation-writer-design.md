# Background aggregation write actor

**Date:** 2026-07-25
**Status:** Approved for planning

## Goal

Let all aggregation runs execute fully in the background without interrupting the UI — including
the article-insertion/upsert step, which today hops back to the main actor and, together with
per-feed `save()`s and the resulting full-index republishes, stutters the reader during a refresh.

## Problem (current state)

During a run, three kinds of work land on the **main thread**:

1. **Per-article upsert** — `AggregationService.upsert()` hops to `@MainActor` for every article to
   insert/mutate the shared *main* `ModelContext` (`AggregationService.swift:386,419`).
2. **Per-feed `save()`** — each feed's SQLite flush runs on the main context
   (`AggregationService.swift:395,450`).
3. **Re-render storm** — every `save()` fires `ModelContext.didSave`, which makes `ArticleStore`
   reload the whole index and republish `summaries = all`, re-diffing the entire timeline/reader,
   once per feed (`ArticleStore.swift:104,158,165`).

Network/AI and the SwiftSoup HTML→`[Block]` parse already run off-main. What still stutters the UI
is the SwiftData **writes, saves, and the repeated full-index republish** on the main actor.

Everything writes to the shared main `ModelContext` on purpose, so the reader
(`ArticleResolution.resolve(_:in:)`, main context) always sees consistent, non-stale data. Moving
writes to a background context is the real fix but introduces cross-context staleness for articles
the reader already holds, which must be handled.

## Design

### 1. Component split

- **`AggregationWriter` — new `@ModelActor`** (`Yana/Services/AggregationWriter.swift`). Owns its
  own background `ModelContext` and runs the entire per-feed pipeline off the main actor: fetch
  feeds → run aggregator (async) → AI-process → parse blocks → `ArticleUpsert.apply` → per-feed
  `save()` → retention cleanup. Nothing touches the main context. Mirrors the existing `@ModelActor`
  loaders (`ArticleSummaryLoader`, `BlockMigrator`).
- **`AggregationService` stays `@MainActor`**, slimmed to a **coordinator**. Its public API
  (`updateAll`, `update(feed:)`, `update(article:)`, `forceReload(feed:)`, `forceReload(article:)`,
  `summarize`) and its `@Observable` UI state (`isUpdating`, `updateProgress`, `lastRunFailures`)
  are unchanged, so all call sites (`FeedsView`, `ReaderScreen`/`ReaderHostView`, Mac `TimelineModel`,
  `BackgroundRefreshManager`) keep working verbatim. The coordinator: snapshots main-actor-only
  inputs → calls the writer → performs the main-only follow-ups.

### 2. Actor boundary — Sendable in, Sendable out

No `Feed`/`Article`/`ModelContext` crosses the boundary.

**Request (main → writer), all already `Sendable` or trivially snapshottable:**

- Operation kind + target: `.updateAll`, `.updateFeed(PersistentIdentifier)`,
  `.forceReloadFeed(PersistentIdentifier)`, `.forceReloadArticle(PersistentIdentifier)`,
  `.summarize(PersistentIdentifier)`. `PersistentIdentifier` is `Sendable`; the writer re-resolves
  each in its own context. (`updateAll` lets the writer fetch the enabled feed set itself.)
- source-enabled filter snapshot from `AppSettings` (so `isSourceEnabled($0.type)` is reproducible
  off-main)
- `starredIdentifiers` snapshot from `StarredRegistry` (already returns a `Sendable Set<String>`);
  pass the whole marks snapshot or a `@Sendable (feedIdentifier, aggregatorType) -> Set<String>`
  closure capturing it, so the writer computes per-feed subsets
- `canonicalCreatedAt` snapshot: copy `ArticleSyncService.canonicalCreatedAtByUID` into a
  `Sendable [String: Date]` **after** the coordinator's `pull()`
- `makeAggregator` (`@Sendable AggregatorFactory`), `AIProcessing` processor (`Sendable`),
  logo resolver (`@Sendable`), `AggregatorCredentials`, `now: Date`, `retentionDays`,
  `isPassiveDevice`

**Result (writer → main), `Sendable`:**

- `inserted: Int`
- `failures: [AggregationService.FeedFailure]` (already `Sendable`)
- `touchedUIDs: Set<String>` → coordinator calls `articleSync.push(uids:)`
- `deletedUIDs: [String]` (retention) → coordinator calls `articleSync.deleteRemote(uids:)`

**Progress:** the writer accepts a `@Sendable (ProgressEvent) -> Void` callback; the coordinator's
implementation hops to `@MainActor` to drive `updateProgress` (`.start(total:)`, `.advance()`), so
"Updating N of M…" keeps working with zero main-thread write cost.

**`ArticleUpsert.apply` loses its `@MainActor` annotation** — nothing inside it requires main
isolation; it operates purely on the `context`/`Feed` handed to it — and runs on the writer's actor.
Its default `blocksFor` still parses inline; the writer keeps pre-parsing blocks off the (main)
actor as today, now simply off *its* actor.

### 3. Staleness handling (primary risk)

With writes on a background context, the reader must still see correct data:

- **New inserts** (dominant case): committed by the writer, picked up by `ArticleStore`'s existing
  off-main reload (a fresh `ArticleSummaryLoader` context reads committed rows), published as
  `summaries`; the reader resolves them fresh. No stale main-context copy exists for a new row.
- **In-place updates** (`forceReload`/`summarize`): the main context may hold a stale materialized
  copy of an article the reader already opened. Mitigations:
  - The article-write path becomes **single-writer** through the actor.
  - `ArticleResolution` is made **refresh-safe**: a currently-open page re-reads committed content
    rather than trusting a cached `model(for: persistentID)` fast-path when the store changed.

Because cross-context propagation is the load-bearing assumption, the plan includes an explicit
**integration test**: write via a background context, assert the main context observes both inserts
and in-place updates. Documented fallback if SwiftData's sibling-context merge does not cover
in-place updates: identifier re-fetch and/or an explicit main-context refresh on the affected rows.

The two other article writers stay on the main context and commit to the same store:
`ArticleSyncService.reconcile` (insert/delete on pull) and `ArticleListView` swipe-delete. The
writer's fresh per-run fetch (rebuilds its dedup index from `feed.articles` each run) sees them.

### 4. Error handling / cancellation / durability (preserved exactly)

- Per-feed `save()` after each feed → durable partial batches on cancel/failure.
- Cancellation is not a feed failure (leave `lastError`/state untouched, persist partial batch).
- One feed's failure never aborts the run; the failure is recorded and surfaced via
  `lastRunFailures`.
- Run cap (`AggregationLogic.runLimit`) + intake window + daily-collected count unchanged.
- `Task.isCancelled` still cuts a run short: the coordinator's `Task` cancellation propagates into
  the actor's run loop (checked between feeds and at the existing points).
- The bounded concurrency window (`maxConcurrentFeedUpdates = 5`) is preserved inside the writer.

### 5. Testing

- **Reuse** existing `AggregationService` tests — public API unchanged; they should pass against the
  coordinator.
- **New:** cross-context propagation integration test (§3) — inserts and in-place updates.
- **New:** assert the write path does not run on the main actor (the writer's context is not the
  main context; upsert executes on the actor).
- **New:** progress-callback test — `updateProgress` still reports `start(total:)`/`advance()`.

## Out of scope

- Incremental/diff-based `ArticleStore` publishing (append new summaries instead of republishing
  the whole index). The existing debounced off-main reload is retained; a smoother incremental
  timeline can be a follow-up.
- Any change to the SwiftData store mode — it stays local-only (`cloudKitDatabase: .none`); this is
  purely about which `ModelContext` does the writes.
