# iCloud Article Sync — Design

**Date:** 2026-07-24
**Status:** Approved for planning

## Goal

Give a user with multiple devices an **identical article timeline** everywhere: the same
articles, in the same order, with full bodies and images, plus an exact reading position. This
reverses the current deliberate "article bodies never sync / SwiftData store is local-only"
decision — bodies **and** image blobs now live in the user's iCloud private database.

Everything remains **opt-in** and gated on the existing `AppSettings.iCloudSyncEnabled`.

## Baseline (what exists today)

- **`ConfigSyncService`** syncs a single `ConfigDocument` CloudKit record: feeds/tags (OPML),
  allow-listed settings, starred marks, and (via iCloud Keychain) API keys.
- **Timeline position** syncs as a *timestamp* (the anchored article's `createdAt`); a receiving
  device jumps to the article with the **closest** `createdAt`. This fuzziness exists only because
  timelines aren't identical across devices.
- **Article bodies never sync.** Each device re-fetches on demand; the SwiftData store is local-only
  (`ModelConfiguration(cloudKitDatabase: .none)`). `createdAt` is back-dated per device with random
  jitter, so both the article *set* and its *ordering* differ between devices.

The gap this design closes: make the timeline canonical and identical, and carry full content.

## Decisions (locked during brainstorming)

1. **Canonical UID** = `feedIdentifier|aggregatorType|articleIdentifier`, with a hash-of-`date+title`
   fallback only when `articleIdentifier` is empty. This is the existing `StarredMark` triple; it is
   already deterministic across devices (both devices fetching the same feed get the same
   `Article.identifier`) and collision-free, unlike `date+title+feed`.
2. **Transport** = `CKSyncEngine` (iOS 17+, fine on the iOS 26 floor) over a dedicated CloudKit zone
   with custom records. Not SwiftData native mirroring (can't gate at runtime, would collide with
   config sync, no hook for the pre-insert re-check / passive behavior), not hand-rolled change
   tracking (more code, no upside on a modern OS floor).
3. **Retention / deletion** = deletions propagate. Active devices trim past-retention articles and
   delete the shared record; every device applies the tombstone. **Passive devices never run
   retention and never initiate a delete.** Starred stays exempt.
4. **Timeline position** = exact anchored-article **UID**, always synced (no dedicated toggle). The
   old timestamp + closest-match machinery is removed.
5. **Passive device toggle** replaces the sync-position toggle. Passive = **no background aggregation
   + no retention**; all *manual* fetch paths still work (a passive device can be a temporary
   producer when it's the only one online).
6. **Conflict resolution** = `createdAt` **first-writer-wins** (ordering never reshuffles);
   everything else (title, blocks, images, summary, starred, tags) **last-writer-wins**.

## Architecture

Two independent sync surfaces, both gated on `iCloudSyncEnabled`:

- **`ConfigSyncService` (exists)** — the single `ConfigDocument` record. Two edits only:
  - Timeline position field changes from `timelinePosition: Double?` (timestamp) to
    `timelineAnchorUID: String?`.
  - `starredData` is retired (starred now rides on each article record — see below).
- **`ArticleSyncService` (new)** — a dedicated CloudKit zone (`Articles`) driven by `CKSyncEngine`,
  holding many records. Articles stay in local SwiftData exactly as today; this service mirrors them
  to and from the zone.

### Record types (in the `Articles` zone)

**`SyncedArticle`** — `recordName` = the canonical UID string. Fields:

- `feedIdentifier`, `aggregatorType`, `articleIdentifier` — the UID parts, for feed linking.
- `title`, `url`, `author`, `date`, `iconURL`, `summary`.
- `blockData` — JSON-encoded `[Block]` body. `plainText` — the flattened search/read-aloud surface.
- `createdAt` — canonical, first-writer-wins.
- `isStarred`, `tagNames` — the article's tag snapshot.
- `imageHashes` — the `yana-img://` hashes this body references.
- `leadImageRef`.

**`SyncedImage`** — `recordName` = the content hash; a single `CKAsset` field `blob`.
Content-addressed, so write-once and shared by every article referencing that hash.

**Why this shape:** using the UID as `recordName` makes dedup free at the CloudKit layer (same UID →
same record, cannot duplicate). Images keyed by hash mean a blob uploads once and downloads once no
matter how many articles reference it — mirroring the local content-addressed `ImageStore`.

### `StarredRegistry` consequence

Starred now rides on each `SyncedArticle` as `isStarred`, so the `starredData` field in
`ConfigDocument` is retired. `StarredRegistry` is kept only for its import-time re-star role (a
freshly aggregated article that is already starred comes in starred); if the article-sync pull covers
that adequately, `StarredRegistry` can be removed entirely during implementation.

## Sync flows

### Local aggregation → push (active devices, or manual on passive)

1. `AggregationService` fetches and builds candidate articles as today (intake window, daily cap, AI
   post-processing).
2. **Pre-insert re-check:** before committing inserts, `ArticleSyncService` checks whether each
   candidate UID already exists in the zone (via `CKSyncEngine` state). If it does, adopt the synced
   record (its canonical `createdAt`, body, starred) instead of inserting a divergent local copy — a
   local upsert by UID rather than a new row.
3. For genuinely new UIDs: insert locally, then hand them to `CKSyncEngine` to push. Each article's
   referenced image hashes upload as `SyncedImage` records **only if absent** (content-addressed
   write-once); then the `SyncedArticle`.

### Pull (all devices, incl. passive)

1. `CKSyncEngine` delivers zone changes (silent push subscription + on launch).
2. Each incoming `SyncedArticle`: if the UID exists locally → last-writer-wins body update
   (`createdAt` untouched); if not → materialize a new local `Article`, link it to its `Feed` by
   `(feedIdentifier, aggregatorType)`, or hold it **unlinked** until the feed arrives via config sync
   (never drop it).
3. Referenced images: fetch any missing `SyncedImage` blobs and write them into the local
   `ImageStore` by hash so `yana-img://` refs resolve. Bodies render lazily, so an image can arrive
   slightly after its article without breaking the reader.
4. Tombstones → remove the local `Article` by UID.

### Deduplication (five layers)

| Layer | Mechanism |
|---|---|
| Local re-fetch | existing upsert by `identifier` within feed |
| Pull | UID exists locally → update, never insert |
| Pre-insert re-check | UID exists in zone → adopt synced, skip insert |
| Push | `recordName` = UID → CloudKit overwrites, no duplicate |
| Images | `recordName` = hash → write-once, shared |

"Normal sync ignores already-aggregated articles" = the pull + pre-insert layers: a UID already
present locally or already in the zone never produces a new row or a redundant upload.

## Retention & deletion propagation

- **Active devices** run retention as today (age off past `retentionDays`, keyed on the canonical
  `createdAt`, Starred exempt), and deletion also tells `CKSyncEngine` to delete the `SyncedArticle`.
  `SyncedImage` blobs are left in place (cheap, content-addressed, possibly shared; an orphan
  garbage-collection sweep is out of scope for v1).
- **Passive devices** never run retention and never initiate a delete; they only apply incoming
  tombstones.
- Result: every device converges on an identical set.

## Passive/active device

- New `AppSettings.isPassiveDevice` (default off = active). Persisted, **device-local, never synced**
  (it describes this device's role, not shared config).
- When passive: `BackgroundRefreshManager` skips registering/running the `BGAppRefreshTask`, and
  retention cleanup is skipped. All manual fetch paths still work.
- Replaces the removed `syncTimelinePositionEnabled` toggle in the iCloud Sync settings section.

## Timeline position (simplified)

- Position becomes the anchored article's **UID string**, carried in the config `SyncedSettings`
  payload (small; debounced through the existing `requestPush`).
- On pull, the receiving device resolves that exact UID to its local `Article` and jumps there — no
  closest-timestamp search. Timelines are identical, so it always resolves precisely.
- Remove `timelinePosition: Double?`, `timelinePositionTimestamp`, the
  `timelinePositionDidChange`-via-timestamp closest-match resolver, and `syncTimelinePositionEnabled`.
  Replace with `timelineAnchorUID: String?`.

## Conflict resolution

- `createdAt` — **first-writer-wins**: adopt the record's existing value on any re-touch (including
  the original author on a re-fetch), so timeline ordering never reshuffles.
- Everything else (title, blocks, images, summary, starred, tags) — **last-writer-wins** via
  `CKSyncEngine` change tags. Bodies are regenerable, so a lost update just re-fetches.

## Migration / first run

- Existing config-sync users: on first launch with article sync, an **active** device does a one-time
  full push of its retained local library into the `Articles` zone (batched). Passive devices skip
  this.
- A brand-new passive device: config sync brings feeds/tags/settings, then the article pull hydrates
  the whole retained set + images from iCloud — no aggregation needed.
- The removed timeline-position settings drop cleanly once the UID anchor lands.

## Quota

Bodies + image blobs consume the user's **iCloud private-DB quota**, counted against *their* iCloud
storage (not the developer's). A month of image-heavy feeds is the realistic ceiling; retention
propagation keeps it bounded. This is an inherent, accepted cost of real article sync.

## Testing strategy

- **Unit** (Swift Testing, no CloudKit): a `FakeArticleZoneStore` mirroring the existing `ConfigStore`
  fake pattern. Cover:
  - UID derivation + `date+title` fallback.
  - All five dedup layers.
  - Pre-insert re-check adopting a synced copy instead of inserting.
  - `createdAt` first-writer-wins; body last-writer-wins.
  - Article-arrives-before-feed → held unlinked, then linked when the feed appears.
  - Tombstone application removes the local article.
  - Passive device skips aggregation and retention.
- **Image path:** hash → `SyncedImage` write-once; missing-blob fetch writes into `ImageStore`; refs
  resolve.
- **Integration/manual:** two-simulator convergence — aggregate on active A, appears identical on
  passive B; star on A reflects on B; retention on A tombstones the article on B.

## Out of scope (v1)

- `SyncedImage` orphan garbage collection.
- Any change to the local-only nature of *feeds/tags* config (still via `ConfigSyncService`).
- Selective/partial sync (e.g. per-tag). The whole retained library syncs.
