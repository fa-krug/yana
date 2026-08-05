# Read-State Sort + Mark-Read + Offline Write Queue + Unread Badge

**Date:** 2026-08-06
**Status:** Draft, pending user review
**Related:** [2026-08-05-server-api-client-rework-design.md](2026-08-05-server-api-client-rework-design.md)
(that spec decoded the server's `read` wire field but deliberately left it unused, "preserves the
existing 'no read/unread state' product decision." This spec reverses that decision.)

## Problem

The server's `/api/v1/articles/sync` payload already includes a `read: Bool` field per article
(`SyncArticleSummaryWire.read`), but nothing in the app writes or reads it — there is no read/unread
state on `Article` at all, and the timeline is a single `createdAt`-ordered stream. We want to use
the server's read state to reorder the timeline so read articles are worked through first and the
next unvisited article is always obvious, mark articles read automatically as the user reads them,
and (while touching the same starred/read write path) stop silently losing local star/read changes
made while offline.

## Goal

- Sort the timeline by read-state first, then date: **read articles (oldest→newest), then unread
  articles (oldest→newest)** — so the oldest unread article is always the boundary the user lands on
  next.
- Mark an article read automatically the moment it becomes the currently-displayed article, on both
  iOS (swipe in the reader, or opening from the article list) and Mac Catalyst (sidebar selection).
- Replace today's "roll back on failure" pattern for both `starred` and (new) `read` with a small
  local pending-write queue, flushed opportunistically on every sync — so a star/read change made
  offline is retried later instead of silently reverting.
- Add an opt-in (default off) app-icon unread-count badge, respecting the user's current timeline
  filter.

## Decisions

| Decision | Choice |
| --- | --- |
| Sort order | Compound: `readRank` (0=read, 1=unread) ascending, then `createdAt` ascending. Read block first, unread block second; oldest-first within each. |
| Why a derived `readRank: Int` instead of sorting on `Article.read` directly | `Bool` does not conform to `Comparable`, so it cannot be used in a SwiftData `SortDescriptor`. `readRank` is a stored `Int` kept in sync via `read`'s `didSet`. |
| Mark-read trigger | Any time an article becomes the current/displayed one: iOS pager transition completion and list-open; Mac sidebar selection change (both user-driven paths only, matching how `ReaderAnchorController`/`TimelineModel` already distinguish user-driven navigation from programmatic reanchoring). |
| Sync conflict rule for `read` | Local wins once true: `SyncWriter` only ever applies `summary.read == true` onto an existing local article; it never sets `article.read = false` if already `true` locally. The server can upgrade unread→read (e.g. read from another device) but a sync pass can never downgrade read→unread. |
| Sync handling for `starred` | Unchanged — still overwritten unconditionally from the server on every sync, as today. |
| Failure handling for `setStarred`/`setRead` PATCH calls | No rollback. On failure, the change is enqueued in a new local pending-write queue instead of being reverted. This replaces the existing rollback behavior for `starred` as well as covering the new `read` write. |
| Pending-write retry trigger | Opportunistic: `SyncEngine.sync()` flushes the pending-write queue first (retrying each entry) before doing its normal pull. No separate scheduling/backoff mechanism. |
| Unread indicator in `ArticleListView` | A small dot next to the title when `!article.read`. |
| App icon badge | New `AppSettings.showUnreadBadge: Bool`, default `false`, toggle in `NotificationsSettingsSection`. Badge count = unread articles matching the **current persisted timeline filter** (tag/feed/starred-only), not the full library. Recomputed whenever `ArticleStore`'s index changes while the setting is on; cleared immediately when turned off. |
| Mac Catalyst scope | In scope for this pass, not deferred — `TimelineModel` gets the same sort and the same mark-read-on-select hook. |
| Filter feature (unread-only toggle) | Explicitly out of scope for this pass — only sort order and auto-marking change; no new filter chip. |

## Architecture

### Data model

- `Yana/Models/Article.swift`: add
  ```swift
  var read: Bool = false {
      didSet { readRank = read ? 0 : 1 }
  }
  var readRank: Int = 1
  ```
  Add `\.readRank` to the model's `#Index` alongside the existing `\.createdAt`.
- `Yana/Models/ArticleSummary.swift`: add `isRead: Bool`, populated from `article.read` exactly like
  `isStarred` is from `article.starred` today (init from `Article`, `CodingKeys`, custom
  `encode`/decode for the disk-cache form).
- `Yana/Utilities/TimelineFiltering.swift`: add a `filterRead`-style property to `TimelineFilterable`
  for both `Article` and `ArticleSummary` (mirroring `filterStarred`'s shape), even though no filter
  UI consumes it yet in this pass — kept for symmetry and to avoid a second plumbing pass later.

### Sort order

Every fetch that currently sorts purely by `createdAt` switches to a compound sort:
`SortDescriptor(\.readRank, order: .forward)` then `SortDescriptor(\.createdAt, order: .forward)`.
This applies to:
- `ArticleSummaryLoader.load()` (`Yana/Services/ArticleStore.swift`)
- `loadWindow`'s forward/reverse split
- `lightDescriptor`

`articlesMissingContent`'s sort in `SyncWriter.swift` (content-backfill query, unrelated to display
order) is unaffected.

Because `ArticleStore` holds the full index in memory and windowing/anchoring already resolves
position by article identifier (via `TimelinePageIndex.index(of:in:)`) rather than raw array offset,
an article moving from the unread block to the read block mid-session (because the user just read it)
is expected to self-heal through the same reanchoring path that already handles list mutations —
no new reconciliation logic is being added. Mac `TimelineModel` reads from the same sorted source, so
it inherits the new order without separate sort logic.

### Marking read

New `ArticleActions.setRead(_:articleServerID:)`, mirroring `setStarred`'s shape:
```swift
private struct ReadBody: Encodable { let read: Bool }
private struct ReadResponse: Decodable { let id: Int; let read: Bool }
func setRead(_ read: Bool, articleServerID: Int) async throws {
    let _: ReadResponse = try await client.patch("/api/v1/articles/\(articleServerID)", body: ReadBody(read: read))
}
```

A new helper (e.g. `ArticleActions.markRead(_ article: Article, modelContext:)` or a small
free function alongside the existing star-toggle call sites) does:
1. If `article.read` is already `true`, no-op.
2. Set `article.read = true`, save.
3. If paired (`AuthenticatedClient.current()` and `article.serverID` both non-nil), fire the PATCH in
   a `Task`; on failure, enqueue into the pending-write queue instead of rolling back.

Call sites (mirroring where `ReaderAnchorController`/`TimelineModel` already record "this article is
now current"):
- iOS: `ReaderArticleViewController.pageViewController(didFinishAnimating:...)`, right where `index`
  and `onIndexChange` are updated.
- iOS: `ReaderHostView.openArticle` (opening an article from the list).
- Mac: `TimelineModel.selection`'s setter and `moveSelection(by:)`.

### Pending-write queue

A new small service, `Yana/Services/PendingWriteQueue.swift`, persists a list of pending writes —
`{articleServerID: Int, field: .starred(Bool) | .read(Bool)}` — most simply as a `Codable` array
stored in `AppSettings` (no new SwiftData model needed; this is small, transient, device-local state,
not something that needs to be queried/joined). API:
- `enqueue(articleServerID:field:)` — replaces any existing pending entry for the same
  `(articleServerID, field-kind)` pair rather than appending duplicates.
- `flush(using: ArticleActions) async` — attempts each pending entry's PATCH; removes on success,
  leaves in place on failure. Called at the start of `SyncEngine.sync()`, before the pull.

Both `ArticleActions` call sites for `starred` (`ReaderHostView.swift`, `ArticleListView.swift`) and
the new `read` call site adopt this: on PATCH failure, `PendingWriteQueue.enqueue(...)` instead of the
current `article.starred = !newValue; try? modelContext.save()` rollback.

### Sync-side handling

`SyncWriter.upsertSummaries` (both insert and update branches) sets `article.read` from
`summary.read`, but on update only when `summary.read == true` — i.e.
`if summary.read { article.read = true }` (never unconditionally assigns, unlike `starred`, which
keeps its existing unconditional overwrite). On insert, `article.read = summary.read` unconditionally
(no local state exists yet to protect).

### Unread indicator

`ArticleListView`'s row view adds a small dot (leading edge, next to the title) shown when
`!article.read` (via `ArticleSummary.isRead`).

### App icon badge

- `AppSettings.showUnreadBadge: Bool`, default `false`; toggle added to `NotificationsSettingsSection`.
- A small helper computes the unread count by applying the same `TimelineFiltering` predicates
  (`TagFilter`/`FeedFilter`/`StarredFilter`, per current `AppSettings` selections) already used to
  build the on-screen list, then counting `!isRead` among the filtered set.
- Recomputed and set via `UIApplication.shared.applicationIconBadgeNumber` (Catalyst: same API is
  available) whenever `ArticleStore`'s published index changes and `showUnreadBadge` is `true`;
  cleared to 0 immediately when the setting is switched off.

## Testing

- `Article`/`readRank` derivation: flipping `read` updates `readRank` correctly in both directions.
- Sort order: a mixed read/unread, mixed-date fixture set produces read-block-then-unread-block,
  oldest-first within each.
- `SyncWriter`: update path never downgrades an already-`true` local `read`; insert path takes the
  wire value unconditionally; `starred` behavior is unchanged (regression check).
- `PendingWriteQueue`: enqueue dedupes by `(articleServerID, field-kind)`; `flush` removes
  successfully-retried entries and leaves failed ones queued.
- Mark-read hooks: swiping to a new article in the iOS pager and opening an article from the list
  both mark it read exactly once (no duplicate PATCH calls); Mac selection change does the same.
- Badge count: computed correctly against each filter combination (no filter, tag filter, starred
  only, feed filter).

## Documentation impact

`CLAUDE.md`'s **Key patterns** section currently states "No read/unread state" as a settled product
decision — this needs to be rewritten to describe the new read-state sort/mark-read/badge behavior
instead. The **Architecture → Models** and **Sync** sections' descriptions of `Article`/`SyncWriter`
also need updates to mention `read`/`readRank` and the pending-write queue.
