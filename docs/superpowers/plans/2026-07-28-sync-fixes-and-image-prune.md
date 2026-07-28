# Plan — Sync fixes and orphaned-image prune

Five independent defects found while reading a Production sync diagnostics log from a Mac
Catalyst build (app 1.1.0 (194), 3363 articles / **15142** images) plus three user-reported
symptoms. Each task is a separate defect; they are ordered so that shared files are never
touched by two tasks at once.

## Context

- Yana is a self-contained SwiftUI RSS aggregator. SwiftData is the store; iCloud sync is
  native SwiftData+CloudKit mirroring (`ModelConfiguration(cloudKitDatabase: .automatic)`),
  always on, no opt-in toggle.
- `Feed`, `Tag`, `Article`, `StoredImage` mirror to the user's private CloudKit database.
  Non-secret prefs sync separately through `NSUbiquitousKeyValueStore` (`SettingsCloudSync`).
- Read `CLAUDE.md` at the repo root for architecture. It is accurate and current.

## Global Constraints

These bind every task. A violation is a defect even when the task text does not repeat it.

1. **Swift 6 strict concurrency.** `@MainActor` annotations throughout; no data races, no
   `@unchecked Sendable` escapes.
2. **`@ModelActor` runs on its caller's thread.** Every main-actor → `@ModelActor` call MUST be
   wrapped in `OffMainActor.run` (`Yana/Utilities/OffMainActor.swift`). Awaiting a `@ModelActor`
   directly from the main actor performs the fetch/save ON the main thread. This is the single
   biggest main-thread hazard in this codebase — see the note in `CLAUDE.md` under Key patterns.
3. **No SwiftData model changes.** Do not add, rename, or retype any stored property on `Feed`,
   `Tag`, `Article`, or `StoredImage`. The CloudKit schema is derived from these models and must
   be re-deployed to Production by hand when it changes; no task here is worth that. Use
   existing fields and device-local `UserDefaults` instead.
4. **CloudKit model invariants** (if a model is touched at all, which it should not be): every
   attribute optional or defaulted; every relationship optional with an inverse; no `#Unique` /
   `@Attribute(.unique)`.
5. **Translations are mandatory.** Every new or changed user-facing string gets an entry in
   `Yana/Resources/Localizable.xcstrings` with a `de` translation marked
   `"state" : "translated"`. German follows Apple style (infinitive for actions, no "Du"/"Sie").
   Count-bearing strings need an explicit `en` plural block too — see the "Count-bearing
   strings" note in `CLAUDE.md`; `"%lld entries"` is the reference shape. Purely internal
   `SyncLog` message text is not user-facing and is not localized (match the existing style in
   the file you are editing).
6. **Tests are Swift Testing** (`import Testing`), in `YanaTests/`, `@MainActor` where they
   touch main-actor state. Pure decision logic must be extracted into a `nonisolated`,
   SwiftData-free type and unit-tested directly — do not write a test that needs CloudKit, a
   real iCloud account, or a UI host.
7. **Build must pass for both destinations:**
   `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
   and `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build`
   (Catalyst: compile only — it cannot be *run* or codesigned from an automation shell, see
   `CLAUDE.md` codesigning gotchas; a `codesign … errSecInternalComponent` failure at the very
   end of a Catalyst build is environmental, not your defect, and the compile result still
   counts).
8. **Run the unit tests:**
   `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`.
   Note that "Executed 1 test" in the tail refers to the XCTest UI test; Swift Testing reports
   its ~559 tests separately. Do not claim a pass you have not seen in output.
9. **Do not run `xcodegen generate` unless you added or deleted a file**, and if you do, do not
   commit unrelated `.xcodeproj` churn.
10. **Mac UI cannot be visually verified in this environment.** Mac Catalyst builds cannot be
    launched from an automation shell. For Mac-only UI behaviour, correctness comes from
    extracted testable logic plus careful reading — say plainly in your report that runtime
    verification was not possible.

---

## Task 1 — Prune orphaned `StoredImage` rows and disk blobs

### The defect

`StoredImage` rows are created but never deleted. `ImageSync.ensureStored`
(`Yana/Services/ImageSync.swift`) is insert-only, and `RetentionCleanup.run`
(`Yana/Aggregators/RetentionCleanup.swift`) deletes only `Article` rows. `grep -rn
"prune\|orphan\|unreferenced"` over `Yana/` returns nothing. So every month retention deletes
articles while their image blobs stay forever — as SwiftData rows, as mirrored CKAssets against
the user's iCloud quota, and as files in the `ImageStore` disk cache. The reporting library
shows 3363 articles against 15142 images.

### What to build

A prune pass that deletes `StoredImage` rows whose `contentHash` nothing references any more,
plus the matching `ImageStore` disk files.

**Safety is the hard part of this task, not the deletion.** A `StoredImage` delete propagates
through CloudKit to every other device. If this device's article set is incomplete — mid-import,
partially synced, a fresh install still pulling down — the blobs look unreferenced here while
another device still needs them, and pruning would destroy them everywhere. So:

1. **Two-phase quarantine, persisted device-locally.** A hash is deleted only if it was already
   seen unreferenced by an earlier pass at least `quarantinePeriod` (use **24 hours**) ago. Pass
   one records candidates with a local timestamp; a later pass deletes those still unreferenced.
   Store the candidate map in `UserDefaults` — device-local, NOT in `AppSettings.SyncedSettings`,
   NOT in the SwiftData store. Use the local first-seen time, never `StoredImage.createdAt`:
   `createdAt` mirrors from the originating device, so an imported month-old blob would clear an
   age check instantly and defeat the whole guard.
2. **Refuse to prune a store that looks incomplete.** If the library has zero `Article` rows,
   do nothing at all (a fresh or mid-import store must never trigger a mass delete). Note that
   an empty *referenced* set with articles present is a legitimate state (articles without
   images) — it is the empty *article* table that means "no information yet".
3. **Never prune a hash that is referenced.** `AggregationWriter.referencedImageHashes()`
   already returns the complete referenced set: feed logos plus every lead image and in-body
   image/embed poster across all articles. Reuse it; do not re-derive it.

### Shape

- Extract the decision into a `nonisolated`, SwiftData-free type — e.g.
  `ImagePrunePlan.decide(referenced:stored:candidates:now:quarantinePeriod:)` returning the
  hashes to delete and the candidate map to persist. **All the interesting behaviour is here and
  this is what the tests cover.**
- Put the SwiftData half in a `@ModelActor` (its own background context), called through
  `OffMainActor.run` per Global Constraint 2. `Yana/Services/ImageSync.swift` is the natural
  home (it already owns the `StoredImage` ↔ `ImageStore` bridge and has a `@ModelActor` in it to
  model on) — a new `Yana/Services/ImagePrune.swift` is equally fine if cleaner.
- Add the disk-side delete to `ImageStore` (`Yana/Aggregators/Utils/ImageStore.swift`): it has
  `fileURL(forHash:)`, `fileExists(forHash:)`, `allHashes()` but no remove. Deleting a file must
  also drop the hash from its in-memory `extensions` map.
- Also drop disk files for hashes that have no `StoredImage` row and are unreferenced (the disk
  cache can hold blobs the row set never covered). Same quarantine rule.
- Call it where retention already runs — after the retention cleanup inside an aggregation run,
  off the main actor, not on the launch path. It must not run when `UpdateInterval` is `.off`
  if that is already how retention behaves; match retention's existing placement rather than
  inventing a second schedule.
- Log the outcome to `SyncLog` in the style of the surrounding code, e.g.
  `"Pruned 412 orphaned image(s), 3 disk file(s)"`, and log nothing when there was nothing to do.

### Tests (`YanaTests/`)

Cover with direct unit tests on the pure planner:

- an unreferenced hash is NOT deleted on first sight — it is returned as a new candidate
- an unreferenced hash whose candidate timestamp is older than the quarantine period IS deleted
- an unreferenced hash whose candidate timestamp is younger than the quarantine period is not
- a hash that becomes referenced again is dropped from the candidate map and not deleted
- a referenced hash is never deleted regardless of candidate state
- the empty-article-table guard produces no deletions at all

---

## Task 2 — Make an empty system-log read explicit in the diagnostics log

### The defect

`SystemLogReader.fetch` (`Yana/Services/SystemLogReader.swift`) surfaces a *thrown* error as a
visible entry — good — but a successful fetch that returns zero entries returns `[]` silently.
`OSLogStore` returns only persisted entries, so zero is common and on a locally built Mac
Catalyst run it is the normal case. The consequence is visible in the reporting log: the system
side stops dead at 13:48:30 while the app side keeps logging to 13:48:42, with nothing marking
the gap. A reader cannot tell "Apple logged nothing" from "we could not read Apple's log", and a
mirroring failure that only appears on the system side — for instance the
`Failed to enqueue request … NSCocoaErrorDomain Code=134417` line in that same log, which fires
no `eventChangedNotification` and therefore never reaches `CloudKitSyncMonitor` — looks like a
perfectly clean launch.

### What to build

1. When the fetch succeeds but yields zero entries, return a single synthetic `.system` entry at
   `.notice` saying no persisted CoreData/CloudKit entries were available for this process, and
   that the system log is a best-effort supplement (keep it one line, in the existing message
   style).
2. Add the system-entry count to the exported header in
   `SyncDiagnostics.exportHeader()` / the pinned status header, so a pasted log states how many
   system entries backed it — e.g. a `System Log:` line reading either a count or "unavailable".
   Follow the header's existing line format and localization convention exactly (check
   `Yana/Views/Config/Settings/SyncLogHeaderView.swift` for whether these labels are localized;
   match it, and if they are, Global Constraint 5 applies).

Keep this task small. Do not redesign the diagnostics screen, and do not attempt to *capture*
enqueue failures — no public API posts them, which is exactly why this marker is the fix.

### Tests

- a fetch that yields no entries produces exactly one explanatory entry (inject/refactor
  minimally so this is testable without a real `OSLogStore` — if that is not reachable without
  contorting the design, test the header-composition change and say so in your report)
- the exported header includes the system-entry count / unavailable marker

---

## Task 3 — Refresh `@Query`-backed library views on CloudKit remote merges

### The defect

Reported by the user: *"when I add a new tag on macOS, I just see dedup and no new entries being
added on iOS."*

A CloudKit merge lands below SwiftData, through Core Data. It posts
`.NSPersistentStoreRemoteChange` and **no** `ModelContextDidSave`, so `@Query` is never
re-evaluated. `ArticleStore` works around this with its own remote-change observer (documented
in `CLAUDE.md`); nothing else does. So the `Tag` row really does arrive and really is in the
store, but every `@Query`-backed list keeps showing its stale fetch until some local write
happens to save or the app relaunches. The only thing that reacts today is `LibraryDedup`'s
observer — which is precisely why the user sees a dedup line and no new tag.

Affected: `Yana/Views/Config/TagsView.swift` (`@Query(sort: \Tag.sortOrder)`),
`Yana/Views/Config/FeedsView.swift`, the `MacFilterBar` tag/feed queries inside
`Yana/Reader/Mac/MacRootView.swift`, and the tag picker in
`Yana/Views/Config/FeedEditorView.swift`. Audit for others.

### What to build

1. A small `@MainActor @Observable` revision counter — e.g.
   `Yana/Services/LibraryRevision.swift`, `LibraryRevision.shared` with a `private(set) var
   token: Int` — that observes `.NSPersistentStoreRemoteChange` and bumps `token`. Coalesce with
   the existing `TrailingCoalescer` (`Yana/Utilities/TrailingCoalescer.swift`): a large sync
   fires that notification many times per second and one rebuild per notification would thrash
   the UI. `LibraryDedup.startObserving` is the pattern to copy.
2. Start it once at launch alongside the other observers in `YanaApp`'s scene `.task`.
3. Make the affected views re-read when `token` changes. **Do not destroy user-entered state
   doing it:** a bare `.id(token)` on `TagsView` would also reset its `searchText`, its
   create-sheet presentation, and any in-flight edit. Either apply the `.id()` to the narrowest
   subview that owns the `@Query` (with search text and sheet state held by the parent), or
   re-read explicitly. Whichever you pick, the acceptance bar is: a remote insert appears
   without a relaunch, and typing in the search field while a merge arrives loses nothing.

Note `.NSPersistentStoreRemoteChange` **also fires for local saves** on a `.automatic` store,
several times per save (`ArticleStoreIncrementalTests` pins this). A rebuild on a local save is
harmless here — a re-fetch is cheap for tags/feeds — but it is another reason the coalescing is
required, not optional.

### Tests

- the revision token bumps once for a burst of notifications, not once per notification
- the token bumps again for a later, separate burst
Model these on the existing coalescer/observer tests rather than inventing a new harness.

---

## Task 4 — Propagate the timeline anchor as it changes, and apply it on Mac

### The defect

Reported by the user: *"the current selected article is not updated when I scroll through the
articles."*

The reading position is meant to sync: `AppSettings.SyncedSettings` carries
`timelineAnchorUID`, and `applySyncedSettings` posts `AppSettings.timelinePositionDidChange` so
a receiving device can jump to that article. Two bugs break it end to end:

1. **It is almost never pushed.** `SettingsCloudSync.push` is called from exactly two places:
   scene `.background` in `Yana/YanaApp.swift:158`, and once from
   `NativeCloudKitMigration`. Scrolling the reader writes
   `settings.timelineAnchorIdentifier` / `timelineAnchorSyncUID` to `UserDefaults`
   (`Yana/Reader/ReaderHostView.swift:275`, `:307`; `Yana/Reader/Mac/TimelineModel.swift:55`,
   `:82`) and stops there. On a Mac window that stays open, `.background` effectively never
   arrives, so the position never leaves the device.
2. **Mac never applies an arriving anchor.** `AppSettings.timelinePositionDidChange` is observed
   only in `Yana/Reader/ReaderHostView.swift:253` (iOS). `TimelineModel` has no observer, so a
   remote anchor cannot move the Mac selection.

There is also a latent third bug: `applySyncedSettings` posts `timelinePositionDidChange`
whenever the decoded payload merely *contains* a `timelineAnchorUID`, changed or not — so every
unrelated settings pull yanks the reader back to the anchor.

### What to build

1. A coalesced push. Add something like `SettingsCloudSync.pushSoon(_:)` built on
   `TrailingCoalescer` (a few seconds of quiet — pick and document a value; scrolling a timeline
   must not mean one KVS write per article) and call it from the anchor write sites above. Keep
   the existing `.background` push as the flush.
2. `applySyncedSettings` posts `timelinePositionDidChange` **only when the decoded UID actually
   differs** from the stored one.
3. `TimelineModel` observes `timelinePositionDidChange` and moves `currentIndex` to the article
   whose `uid` matches `settings.timelineAnchorSyncUID`, ignoring it when no article matches
   (the article may not have synced yet). Wire the observer where the model is configured, and
   tear it down correctly.
4. **No ping-pong.** Applying a remote anchor must not itself trigger a push, or two open
   devices will trade anchor writes forever. Only user-driven selection changes push. Make this
   explicit in the code, not incidental — it is the failure mode that would look like "the
   reader keeps jumping".

### Tests

- `applySyncedSettings` posts `timelinePositionDidChange` for a changed UID and does NOT post
  for an unchanged one
- the anchor write path pushes (assert against the existing injectable `KeyValueStore` fake —
  `SettingsCloudSync` already takes one), and a burst of anchor changes coalesces into one push
- resolving a synced UID to an index: matching UID selects it, absent UID leaves selection
  untouched (extract as pure logic if it is not already — `TimelinePageIndex` is the neighbouring
  pattern)

---

## Task 5 — Scroll the Mac sidebar to the selected article

### The defect

Reported by the user: *"macOS also doesn't focus the article list on the current selected
article."*

`MacSidebarView` in `Yana/Reader/Mac/MacRootView.swift` binds `List(selection: $model.selection)`
and relies on the List to follow selection itself — see the comment above the `List`, which
deliberately avoided a `ScrollViewReader` to keep the source-list chrome. It does not follow at
launch (rows are not laid out yet when the restored anchor is applied), and it does not follow
when selection moves from somewhere other than a click — the ⌘↑/⌘↓ menu commands
(`MacCommands.swift` → `TimelineModel.moveSelection`), the restored anchor in `applyTimeline`,
and, once Task 4 lands, an anchor arriving from another device.

### What to build

Make the sidebar scroll the selected row into view when the selection changes **programmatically**,
without hijacking the user's own scrolling.

- Give `TimelineModel` an explicit scroll request — e.g. a `scrollTarget: (id: String, token:
  Int)?` or equivalent — bumped **only** by the programmatic paths (`moveSelection`, the anchor
  restore in `applyTimeline`, and the remote-anchor apply added in Task 4) and **not** by the
  `selection` setter that the List itself drives on a click. This distinction is the whole
  design: bumping it from the `selection` setter would fight the user's scrolling.
- Consume it in `MacSidebarView` with a `ScrollViewReader` and `proxy.scrollTo(id, anchor:
  .center)`. Keep `.listStyle(.sidebar)` explicitly applied so the source-list chrome survives
  the wrapper — and read the existing comment above the `List` before you change that structure;
  it documents a real prior failure. If wrapping proves to break the column styling, an
  equivalent modifier-based approach is acceptable, but say which you used and why in your report.
- Scroll on first appearance too, once `filteredArticles` is non-empty and the restored anchor
  has been applied — that is the launch case the user is reporting.

### Tests

The scroll itself is UIKit/SwiftUI behaviour and cannot be asserted here (Global Constraint 10).
Test the request logic, which is where the bugs live:

- `moveSelection` bumps the scroll request
- setting `selection` (the click path) does NOT bump it
- the anchor restore bumps it
- a remote-anchor apply bumps it
- the token changes even when the target id is unchanged, so a repeated request is not swallowed

---

## Out of scope

- The 12.4 s launch import in the reporting log. That is `NSPersistentCloudKitContainer` applying
  a merge batch; there is no public knob for it, and the app-side reaction is already
  incremental.
- The duplicate `UIScene`/activation notification burst (11 in one second) and the resulting
  rejected `AppActivationExport`. Benign, and driven by Catalyst's multi-`WindowGroup` scene
  model rather than by app code.
- Anything requiring a CloudKit schema change (Global Constraint 3).
