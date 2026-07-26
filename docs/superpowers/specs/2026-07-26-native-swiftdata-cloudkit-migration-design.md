# Native SwiftData + CloudKit Migration

**Date:** 2026-07-26
**Status:** Approved design

## Goal

Replace the hand-built CloudKit sync stack (`CKSyncEngine` article zone + `ConfigDocument`
config record) with **native SwiftData + CloudKit mirroring**. Sync is **always active** — no
opt-in toggle, no passive-device mode. In its place, a per-device **update interval** setting
controls how often (if at all) the device aggregates. A **one-time migration** moves existing
users from the old stack to the new one.

## Decisions (from brainstorming)

1. **Images sync too** — image blobs move into the SwiftData store (`@Attribute(.externalStorage)`)
   so CloudKit mirrors them as CKAssets. No per-device re-fetch.
2. **Update interval is per-device (local)** — `no update / 30min / 60min / 2h / 4h / 8h / 24h`.
   `no update` = a pure mirror (receives synced data, never aggregates or runs retention). Replaces
   passive mode.
3. **Keep both settings sync and key sync, always on** — allow-listed non-secret prefs sync via
   `NSUbiquitousKeyValueStore`; API keys sync via iCloud Keychain (always synchronizable, no toggle).
4. **Delete old CloudKit data on migration** — the custom `Articles` zone, `ConfigDocument` record,
   and `SchemaBootstrap` zone are removed from the user's private DB (retried until it succeeds).

## Non-goals

- No change to the aggregation pipeline, reader, or block model.
- No SwiftData store *format* migration beyond the additive `StoredImage` model — the same store
  file gains CloudKit mirroring in place.
- The update interval does **not** sync; each device chooses its own.

---

## 1. Data model & container

### Container

`AppContainer.shared` (in `Yana/YanaApp.swift`) switches from
`ModelConfiguration(cloudKitDatabase: .none)` to `ModelConfiguration(cloudKitDatabase: .automatic)`
for the production store. The DEBUG screenshot/UITest temp stores stay `.none` (no sync during
capture, matching the existing throwaway-store behavior).

When the user is not signed into iCloud, SwiftData mirroring silently degrades to local-only —
no error surface, no toggle.

### Models

`Feed`, `Tag`, `Article` are already CloudKit-compatible and need **no structural change**:
- All attributes have default values or are optional.
- All relationships are optional with inverses (`Feed.articles` ↔ `Article.feed`,
  `Feed.tags` ↔ `Tag.feeds`, `Article.tags` ↔ `Tag.articles`).
- No `#Unique` constraints. The existing non-unique `#Index<Article>([\.createdAt],[\.identifier])`
  is retained (CloudKit allows non-unique indexes).

**New model — `StoredImage`:**

```swift
@Model
final class StoredImage {
    var hash: String = ""                              // content hash; matches yana-img://<hash>
    @Attribute(.externalStorage) var data: Data = Data()
    var createdAt: Date = Date.now
    init(hash: String, data: Data) { … }
}
```

Registered in the `ModelContainer` schema alongside `Feed`, `Tag`, `Article`. External-storage
binary data mirrors to CloudKit as a `CKAsset`, so images propagate across devices.

### ImageStore as a cache

`ImageStore` is demoted from source-of-truth to an **on-disk cache** in front of `StoredImage`:
- `storeData` writes the blob to disk (as today) **and** upserts a `StoredImage` row (by hash).
- Resolving `yana-img://<hash>`: serve from the disk cache; on a miss, fetch `StoredImage` by
  `hash`, write its `data` back to the disk cache, then serve. Reader and `leadImageRef` paths are
  unchanged.
- Content-addressing means `StoredImage` rows are write-once; re-storing an existing hash is a
  no-op upsert.

### Dedup

CloudKit cannot enforce uniqueness, and two devices can independently create the "same" logical row
(e.g. both aggregate a feed before syncing, or two pre-migration libraries merge on first sync). A
`LibraryDedup` service runs **debounced after remote merges** (and once right after migration):

- **`Feed`** — collapse duplicates by `(aggregatorType, identifier)`.
- **`Tag`** — collapse duplicates by `name` (built-in "Starred" included).
- **`Article`** — collapse duplicates by `(feed.identifier, identifier)` (falling back to the same
  `SHA256(date+title)` third segment the old `ArticleUID` used when the source gives no identifier).

For each duplicate group: keep the survivor with the **earliest `createdAt`** (preserving the stable
first-writer-wins timeline order), re-point relationships (articles → survivor feed, tag memberships
merged), **OR** the starred state (a `Starred` tag membership on any duplicate is applied to the
survivor), then delete the losers. Deletions propagate via CloudKit like any other delete.

Merge detection hooks the `ModelContext.didSave` / remote-change signal that already drives
`ArticleStore`; the pass is coalesced so a burst of incoming CloudKit changes triggers one dedup.

---

## 2. Settings & keys sync (kept, always on, native)

### Prefs → `NSUbiquitousKeyValueStore`

The allow-listed non-secret settings currently in `SyncedSettings` (retention days, AI provider +
model/URL fields, AI tuning knobs, timeline filter state, reader prefs, timeline anchor) move to
`NSUbiquitousKeyValueStore`:

- A small `SettingsCloudSync` helper writes each allow-listed key to KVS on change and observes
  `NSUbiquitousKeyValueStore.didChangeExternallyNotification` to apply remote updates back into
  `AppSettings` (reusing the existing `applySyncedSettings` field-by-field apply, adapted to read
  from KVS instead of a decoded `ConfigDocument`).
- **Excluded from sync (device-local):** `updateInterval` (new), `macSidebarWidth`, voice identifier,
  onboarding flags, and anything already excluded today.
- The timeline anchor keeps its cross-device behavior: the synced canonical anchor identifier rides
  in KVS so a receiving device can jump to the same article.

`backgroundInterval` (previously synced) is **removed from the synced set** — it is superseded by the
device-local `updateInterval`.

### API keys → iCloud Keychain, always on

`KeychainService` becomes **unconditionally synchronizable** (`kSecAttrSynchronizable` always set):
- Remove the `synchronizeWithICloud` flag, `migrateSynchronizable(to:)`, and
  `restoreSynchronizableFlag(...)`.
- A one-time migration re-saves all existing keys into the synchronizable domain (see §4).

---

## 3. Update interval (per-device, replaces passive mode)

### Setting

New device-local enum on `AppSettings` (backed by UserDefaults, **not** synced):

```swift
enum UpdateInterval: String, CaseIterable {
    case off, min30, min60, hour2, hour4, hour8, hour24
    var seconds: TimeInterval? { … }   // nil for .off
}
var updateInterval: UpdateInterval
```

### Behavior

- **`.off`** = pure mirror: `BackgroundRefreshManager` does **not** register/schedule; aggregation is
  never triggered on a timer; retention cleanup is skipped. The device still receives synced
  articles, images, and deletes via CloudKit, and manual "Update"/"Reload" still work.
- Any non-`.off` value: `BackgroundRefreshManager` schedules `BGAppRefreshTask` (best-effort) at the
  chosen cadence, reading `updateInterval.seconds` where it previously read `backgroundInterval`. The
  60-second floor still applies.
- **Retention gating** moves from `isPassiveDevice` to `updateInterval == .off`: `AggregationWriter`'s
  `cleanup(...)` guard becomes `guard settings.updateInterval != .off else { return [] }`. Active
  devices' retention deletions still propagate to `.off` mirrors via CloudKit.
- Mac Catalyst's `NSBackgroundActivityScheduler` loop reads the same interval and honors `.off`.

### Settings UI

- **Remove** the entire iCloud-sync section (`ICloudSyncSettingsSection`) — the toggle and the
  passive-device toggle — from both the iOS Settings screen and the Mac settings window. In its place,
  a static footnote: *"Your library syncs automatically via iCloud."*
- The Library section's background-refresh `Stepper` (300…21600, step 300) becomes a `Picker` over
  the 7 `UpdateInterval` cases with localized labels (`No updates`, `Every 30 minutes`, `Every hour`,
  `Every 2 hours`, `Every 4 hours`, `Every 8 hours`, `Every 24 hours`).
- All new/changed strings get German translations in `Localizable.xcstrings` (Apple infinitive style).

---

## 4. One-time migration

Gated by a new device-local flag `AppSettings.hasMigratedToNativeCloudKit`, run **off the launch
path** from `AppDelegate` (same pattern as `BlockMigration`). Steps, in order, each idempotent:

1. **Seed `StoredImage`** — enumerate existing on-disk `ImageStore` blobs and upsert a `StoredImage`
   row per hash, so pre-migration images mirror up. (Content-addressed → safe to re-run.)
2. **Enable mirroring** — the container is created with `.automatic` from this build on; existing
   feeds/tags/articles in the same store file are exported to CloudKit by SwiftData automatically.
   `StoredImage` is an additive schema change SwiftData migrates lightweightly.
3. **Force keys synchronizable** — re-save all Keychain API keys into the synchronizable domain.
4. **Migrate interval** — map old `backgroundInterval` → nearest `UpdateInterval`; a device that was
   `isPassiveDevice` maps to `.off`.
5. **Migrate prefs to KVS** — write the current allow-listed `SyncedSettings` values into
   `NSUbiquitousKeyValueStore`.
6. **Delete old CloudKit data** — delete the custom `Articles` record zone, the `ConfigDocument`
   record, and the `SchemaBootstrap` zone from the private database. This step is **retried on
   subsequent launches** (its own sub-flag) until it reports success, and never blocks the app or the
   rest of migration if CloudKit is unreachable.

Once steps 1–5 complete, `hasMigratedToNativeCloudKit` is set; step 6 clears its own retry flag on
success independently.

### Code removed

Delete the retired hand-built stack entirely:
- `Yana/Services/ArticleSync/` — `ArticleSyncService`, `CloudKitArticleZoneStore`, `ArticleZoneStore`,
  `SyncedArticleRecord`, `ArticleRecordMapping`, `CloudKitSchemaBootstrap`.
- `ConfigSyncService`, `CloudKitConfigStore`/`ConfigStore`, `ConfigDocument`.
- `StarredRegistry` and the standalone `ArticleUID` machinery — starred now rides natively on
  `Article.tags` (the built-in Starred tag), which mirrors like any other relationship. (The
  `SHA256(date+title)` fallback logic for identifier-less articles is preserved inside `LibraryDedup`.)
- The `AggregationService` pull-before / push-after hooks that called the old article sync.
- `AppSettings.iCloudSyncEnabled`, `isPassiveDevice`, `backgroundInterval`, and the
  `KeychainService.synchronizeWithICloud` flag family.

### Schema deployment

Native mirroring auto-derives the CloudKit schema from the SwiftData model. A DEBUG-only
`initializeCloudKitSchema()` call (now valid — SwiftData generates the underlying managed object
model) pushes the schema to the Development environment on demand, replacing `CloudKitSchemaBootstrap`.
**The schema must be deployed to Production in CloudKit Dashboard before release.**

---

## Testing

- **`StoredImage` + `ImageStore` cache**: storing a blob creates a `StoredImage`; resolving a
  `yana-img://` hash on a cold cache re-materializes from `StoredImage`; re-storing an existing hash
  is a no-op.
- **`LibraryDedup`**: duplicate feeds/tags/articles collapse to the earliest-`createdAt` survivor,
  relationships re-point, starred is OR-ed, losers deleted. No-op when there are no duplicates.
- **`UpdateInterval`**: `.off` skips `BackgroundRefreshManager` registration and retention;
  non-`.off` schedules at the mapped seconds; `backgroundInterval` → `UpdateInterval` mapping,
  passive → `.off`.
- **Migration**: idempotent (re-running does nothing after the flag is set); image seeding is
  content-addressed; the CloudKit-delete step is independently retryable; prefs land in KVS.
- **Settings sync (KVS)**: a remote KVS change applies allow-listed fields into `AppSettings` and
  excludes device-local ones.
- **UI-test isolation** unaffected: production store gets `.automatic`, the UITest/screenshot temp
  stores stay `.none`.

## Risks / notes

- CloudKit mirroring requires the schema-compatibility invariants above to hold for **all future**
  model edits (optionals/defaults, inverse relationships, no `#Unique`). Documented in CLAUDE.md
  update.
- First sync after migration may briefly show duplicates before `LibraryDedup` runs; the pass is
  coalesced and idempotent.
- Deleting the old CloudKit zones touches the user's private DB; the step is best-effort and retried,
  never fatal.
