# Sync Log Viewer (iOS + Mac)

**Date:** 2026-07-27
**Status:** Approved design, ready for implementation plan

## Problem

iCloud sync does not work and there is no way to see why. Yana currently emits **no logging at
all** about CloudKit mirroring: `AppContainer.shared` creates a `ModelConfiguration(cloudKitDatabase:
.automatic)` container and whatever `NSPersistentCloudKitContainer` does afterwards is invisible.
Apple's own `com.apple.coredata` log lines redact the useful parts to `<private>`, so even attaching
Console to the device does not name the failure.

MySquad solves this with a Settings → System Logs screen (`MySquad/Views/Settings/SystemLogsView.swift`).
That viewer is only useful because `MySquadApp.init` installs an
`NSPersistentCloudKitContainer.eventChangedNotification` observer that re-logs the entire error tree
with `privacy: .public` under the app's own subsystem. The viewer and the event logger are one
feature, not two.

## Goal

Add an in-app diagnostics log to Yana on **both iOS and Mac Catalyst**, so a sync failure can be
read on the device that is actually failing — including a TestFlight/App Store build running against
the Production CloudKit environment, which an Xcode-only debugging path can never reach.

## Decisions

| Decision | Choice |
| --- | --- |
| Log source | Own in-app buffer (primary) **plus** `OSLogStore` for `com.apple.coredata` (supplement) |
| Availability | Ships in release builds, but hidden behind a reveal gesture |
| History | Current launch only — in-memory ring buffer, no file persistence |
| Scope of logging | CloudKit sync events + adjacent library operations + a pinned status header |
| Export | Copy to clipboard **and** a `ShareLink` exporting the filtered log as `.txt` |

Rationale for the two-source design: `OSLogStore` returns only *persisted* entries, most CoreData
mirroring chatter is `debug`/`info` level and therefore often absent, and on a locally-run Mac
Catalyst build `os_log` has previously produced a complete blackout (see the
`maccatalyst-local-run-observability` finding). The in-app buffer is the guaranteed source; the
`OSLogStore` read adds Apple's side of the story where it happens to be available.

## Architecture

Three new units under `Yana/Services/`, one new view, and small edits to existing surfaces.

### `SyncLog` — the buffer

```
Yana/Services/SyncLog.swift
```

A `Sendable` final class with a `static let shared`, wrapping an
`OSAllocatedUnfairLock<[Entry]>` ring buffer.

- **Capacity:** 2000 entries, oldest evicted on overflow.
- **Writes are `nonisolated` and lock-protected.** This is required, not stylistic: CloudKit event
  notifications are delivered on an arbitrary queue and arrive in bursts, and the adjacent callers
  (`AggregationWriter`, `LibraryDedup` — both `@ModelActor`) are off the main actor. A
  `@MainActor` API would force a hop per line.
- **Reads are snapshots.** `snapshot() -> [Entry]`. Deliberately **not** `@Observable`: an
  observable array would turn a 200-event export burst into 200 SwiftUI invalidations. The viewer
  pulls on appear, on a ~1 s tick while visible, and on explicit refresh.
- **Mirroring:** every write is also emitted to `Logger(subsystem: AppConstants.bundleID,
  category:)` with `privacy: .public`, so Console and `log stream` keep working when a cable is
  attached.

```swift
struct Entry: Identifiable, Sendable {
    let id: UInt64          // monotonic sequence, assigned under the lock
    let date: Date
    let level: Level        // debug | info | notice | error
    let category: String    // "CloudKit", "ImageSync", "Dedup", …
    let message: String
    let source: Source      // .app | .system  (see SystemLogReader)
}
```

Convenience API: `SyncLog.shared.info(_:category:)`, `.notice`, `.error`, `.debug`.

### `CloudKitSyncMonitor` — the event logger

```
Yana/Services/CloudKitSyncMonitor.swift
```

- Installs the `NSPersistentCloudKitContainer.eventChangedNotification` observer and logs each
  event: `setup` / `import` / `export`, with start, success, and failure.
- On failure, walks the `NSError` tree recursively — every `userInfo` key, every `CKPartialErrors`
  sub-error (both the `[AnyHashable: NSError]` and `NSDictionary` shapes), and `NSUnderlyingError`
  — mirroring MySquad's `logErrorRecursively`. All values public-privacy; this is the payload that
  Apple's own logging hides.
- Reads `CKAccountStatus` for `iCloud.de.fa-krug.Yana` at start and observes
  `CKAccountChangedNotification`.
- Retains `lastImportSucceededAt`, `lastExportSucceededAt`, and `lastError` for the status header.

**Ordering is load-bearing.** `CloudKitSyncMonitor.start()` must run as the **first statement inside
the `AppContainer.shared` closure**, before the live `.automatic` container is created — the same
class of constraint as `CloudKitSchemaInitializer`. Setup events are where a container-, entitlement-,
or account-level failure surfaces, and they fire during `ModelContainer.init`; an observer installed
afterwards misses exactly the events that matter.

The error-tree walker is a **pure function** (`NSError -> [String]`) so it can be unit-tested
without CloudKit.

### `SystemLogReader` — best-effort supplement

```
Yana/Services/SystemLogReader.swift
```

`nonisolated static func fetch() async -> [SyncLog.Entry]`. Opens
`OSLogStore(scope: .currentProcessIdentifier)`, positions at process start, and matches
`subsystem == "com.apple.coredata"`. Maps `OSLogEntryLog` to `SyncLog.Entry` with
`source == .system`. Failures return a single `.error` entry describing the failure rather than
throwing — the viewer must never be empty-and-silent about why.

The viewer's empty state states the limitation plainly: only persisted entries are visible, debug/info
mirroring chatter is often absent, and on a locally-built Catalyst run this source may return nothing.

### Instrumentation points

One-line `SyncLog` calls added to:

| Site | What is logged |
| --- | --- |
| `CloudKitSyncMonitor` | setup/import/export lifecycle + full error tree |
| `ImageSync` | `StoredImage` registrations; cache-miss materialisation result |
| `LibraryDedup` | run start; rows collapsed per type (Feed/Tag/Article) |
| `NativeCloudKitMigration` | what the one-time migration did |
| `LegacyCloudKitCleanup` | zone/record deletions and retries |
| `SettingsCloudSync` | KVS push, pull, external-change notification |
| `AggregationService` | one run summary per `updateAll()`: feeds fetched, articles inserted |
| `CloudKitSchemaInitializer` | folds in its existing `NSLog` lines |

`KeychainService` is deliberately **excluded** — no secrets anywhere near a copyable log.

### Status header

Computed on viewer open, pinned above the list, collapsible:

- iCloud account status (`CKAccountStatus`)
- CloudKit container identifier
- CloudKit environment — Development vs Production, derived from build configuration and the
  `aps-environment` entitlement value
- App version + build, OS version, idiom (iPhone/iPad/Mac)
- Row counts: `Feed`, `Tag`, `Article`, `StoredImage`
- Last successful import / export timestamps
- Last error summary

Given the two most likely causes of the current failure — an environment mismatch (Debug↔Development
vs TestFlight↔Production) and account state — this header may name the bug before any log line is
read.

## The viewer

```
Yana/Views/Config/Settings/SyncLogView.swift
```

Reuses MySquad's row visuals: level icon + colour, category, timestamp, monospaced message with
`textSelection(.enabled)`, `lineLimit(4)`.

- **Status header** (above), collapsible.
- **Filter bar:** search text (matches message + category), level picker (all/debug/info/notice/
  error), source picker (All / App / System). The filter is a **pure function** over `[Entry]`, so
  it is unit-testable without SwiftUI.
- **List:** merged buffer + system entries in chronological order (oldest first, so it reads as a
  trace), scrolled to the newest entry on open, with a live entry count. Auto-refresh on a ~1 s tick
  while visible, plus an explicit refresh button.
- **Copy** button — `UIPasteboard.general.string`, correct on both iOS and Catalyst.
- **ShareLink** — exports the *filtered* set as a `.txt` file. On iPhone this is the only practical
  route into Mail/Files; on Mac it gives Save to Files.
- **Hide Diagnostics** row at the bottom, so the reveal gesture is reversible.

Export line format: `[ISO8601 date] [level] [source] [category] message`.

## Placement and reveal gesture

**Reveal.** `AboutSettingsSection` gains a Version row:
`LabeledContent("Version", value: "1.1.0 (1)")` read from the bundle — Yana displays its version
nowhere today, so this is worth having on its own merits. Five taps/clicks within 3 s sets
`AppSettings.diagnosticsUnlocked` and shows the existing `Toast` ("Diagnostics enabled"). Once
unlocked it stays unlocked until hidden from inside the log view.

`diagnosticsUnlocked` is a new `UserDefaults`-backed `AppSettings` property defaulting to `false`.
It is **device-local**: it is absent from `SyncedSettings`, so `SettingsCloudSync` cannot propagate
it to another device.

**iOS.** `SettingsScreenView` gains a Diagnostics `Section` with a `NavigationLink` to `SyncLogView`,
rendered only when `settings.diagnosticsUnlocked`.

**Mac.** A new `SettingsPane.diagnostics` case ("Diagnostics", `stethoscope`) in
`Yana/Reader/Mac/WindowID.swift`. `MacSettingsWindow` currently iterates `SettingsPane.allCases`;
that becomes a computed `visiblePanes` that drops `.diagnostics` while locked. The detail branch
renders `SyncLogView`.

## Testing

- `YanaTests/SyncLogTests.swift` — ring-buffer capacity and eviction order, monotonic ids,
  concurrent writes from many tasks (no loss, no crash), export text formatting.
- `YanaTests/CloudKitEventLogTests.swift` — the recursive `NSError` walker against a synthesized
  error with a nested `NSUnderlyingError` and `CKPartialErrors` in both dictionary shapes; asserts
  every domain/code/message appears and nesting depth is reflected.
- `YanaTests/SyncLogFilterTests.swift` — the pure filter function: level, source, and text matching,
  including case-insensitivity.
- No new UI test. Existing Settings UI tests must still pass — the About section grows a Version
  row, so check anything relying on `scrollToSettingsRow` and on About's row order.

## Localization

Every new user-facing string goes into `Yana/Resources/Localizable.xcstrings` with a `de`
translation marked `"state": "translated"`, in Apple's infinitive style ("Protokoll kopieren",
"Diagnose ausblenden"). Log *messages* themselves stay English — they are diagnostic payload for a
GitHub issue, not UI copy.

## Non-goals

- No file persistence and no cross-launch history (explicitly decided).
- No general app-wide logging refactor; the reader, aggregators, and AI paths are untouched beyond
  the single aggregation run-summary line.
- No mail-a-report flow — Yana routes reports to the GitHub issue board and has no support address.
- This spec adds **observability**, not a sync fix. Reading the resulting log is the next step.

## Build notes

`xcodegen generate` picks up the new files automatically (the `Yana` target globs the `Yana`
directory). CLAUDE.md's Services list and the Settings description need the new units and the
Diagnostics surface.
