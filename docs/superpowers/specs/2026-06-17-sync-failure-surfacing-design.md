# Sync Failure Surfacing — Design

**Date:** 2026-06-17
**Status:** Approved

## Problem

When a feed sync fails, the user sees only an orange exclamation triangle on the feed in
the Feeds list — with (in their build) no explanation of what went wrong. Investigation
surfaced three distinct facts:

1. **The Feeds-list inline error already works in `main`.** `FeedsView` renders the error
   text below the triangle (`FeedsView.swift:136-141`) from the same `feed.lastError` value
   that drives the triangle. A verification test proved `feed.lastError` is **never** an
   empty string when set — even a bare Swift error yields Foundation's synthesized
   *"The operation couldn't be completed. (…error 1.)"*. The reported "triangle but no text"
   symptom is therefore a **stale build** predating commit `1fc67c6`; a rebuild fixes it.
2. **The reader pull-to-refresh is silent on failure.** `ArticleReaderView.refresh()`
   (`ArticleReaderView.swift:119-122`) calls `updateAll()` and discards everything.
   `AppState.errorMessage` (`AppState.swift:9`) is declared but never set or read — dead code.
   This is the primary surface where users trigger syncs, and it tells them nothing.
3. **Generic/unknown errors are unhelpful.** Real failures (network, HTTP, ATS, parse) already
   produce meaningful messages via `AggregatorError`/`URLError`. But a bare error renders the
   useless *"The operation couldn't be completed. (…error 1.)"*.

## Goals

- Surface sync failures where the user actually syncs (the reader).
- Replace unhelpful generic error text with a clear fallback.
- Make the Feeds-list error message fully readable.

## Non-Goals

- Changing the `Int` return type of `updateAll()` / `update(feed:)` (callers depend on it).
- Retrying or auto-recovering failed feeds.
- Surfacing failures from background refresh (it already posts a new-article notification).

## Design

### 1. Track failures in `AggregationService` (`Services/AggregationService.swift`)

- Add `struct FeedFailure: Sendable, Equatable { let feedName: String; let message: String }`.
- Add `private(set) var lastRunFailures: [FeedFailure] = []`.
- Reset `lastRunFailures = []` at the start of `updateAll()` and `update(feed:)`.
- In `aggregate(feed:)`, on the `notImplemented` guard and in the `catch`, append a
  `FeedFailure(feedName: feed.name, message: <message>)` after setting `feed.lastError`.
- `AggregationService` is `@MainActor`, so the concurrent `updateAll()` task group's appends
  are serialized on the main actor — no data race.

### 2. Friendlier messages — `userFacingMessage(for:)`

A pure static helper (testable), used by `aggregate()` when setting `feed.lastError`:

```swift
static func userFacingMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError,
       let desc = localized.errorDescription,
       !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return desc
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain || ns.domain == NSCocoaErrorDomain {
        return error.localizedDescription
    }
    return String(localized: "An unexpected error occurred.")
}
```

- `AggregatorError` (a `LocalizedError`) and `URLError` keep their existing good messages.
- Bare/unknown errors get the localized fallback instead of the synthesized NSError string.

### 3. Surface in the reader (`ArticleReaderView.swift` + `AppState.swift`)

Pure helper (testable), e.g. `enum SyncFailureSummary`:

```swift
static func message(for failures: [AggregationService.FeedFailure]) -> String? {
    switch failures.count {
    case 0: return nil
    case 1: return String(localized: "Couldn't update “\(failures[0].feedName)”: \(failures[0].message)")
    default: return String(localized: "\(failures.count) feeds couldn't be updated. Check Feeds in Configuration.")
    }
}
```

`refresh()` becomes:

```swift
private func refresh() async {
    let service = AggregationService(context: modelContext)
    await service.updateAll()
    appState.errorMessage = SyncFailureSummary.message(for: service.lastRunFailures)
}
```

Present via `.alert` on the reader (matches the existing import-result alert in `FeedsView`):
title **"Update Failed"**, message `appState.errorMessage`, single **OK** button that clears it.
Binding pattern mirrors `FeedsView`'s `importMessage` alert.

### 4. Feeds-list readability (`FeedsView.swift`)

Remove `.lineLimit(3)` from the error `Text` (`FeedsView.swift:140`) so the full message shows.

### 5. Localization (`Yana/Resources/Localizable.xcstrings`)

Add `de` translations (state `translated`) for every new string:

| Key | German |
|-----|--------|
| `An unexpected error occurred.` | `Ein unerwarteter Fehler ist aufgetreten.` |
| `Couldn't update “%@”: %@` | `„%@“ konnte nicht aktualisiert werden: %@` |
| `%lld feeds couldn't be updated. Check Feeds in Configuration.` | `%lld Feeds konnten nicht aktualisiert werden. Details unter „Feeds“ in der Konfiguration.` |
| `Update Failed` | `Aktualisierung fehlgeschlagen` |

(`OK` already exists.)

## Testing

- `userFacingMessage(for:)`: `AggregatorError` → its description; `URLError` → its
  `localizedDescription`; bare Swift error → `"An unexpected error occurred."`.
- `SyncFailureSummary.message(for:)`: 0 → nil; 1 → single-feed string; n → count string.
- `AggregationServiceTests`: extend so a failing feed populates `lastRunFailures` (name +
  message) and a fully-successful run leaves it empty; a successful `update(feed:)` clears a
  prior run's failures.

## Files Touched

- `Yana/Services/AggregationService.swift` — `FeedFailure`, `lastRunFailures`,
  `userFacingMessage(for:)`, reset/append logic.
- `Yana/Models/AppState.swift` — (no change; `errorMessage` finally used).
- `Yana/Views/ArticleReaderView.swift` — `SyncFailureSummary`, `refresh()`, `.alert`.
- `Yana/Views/Config/FeedsView.swift` — remove `.lineLimit(3)`.
- `Yana/Resources/Localizable.xcstrings` — new strings + German.
- `YanaTests/` — new + extended tests.
