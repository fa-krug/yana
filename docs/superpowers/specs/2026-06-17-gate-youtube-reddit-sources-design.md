# Gate YouTube / Reddit on their Enabled toggle

**Date:** 2026-06-17
**Status:** Approved

## Problem

`AppSettings` already exposes per-source `redditEnabled` / `youtubeEnabled` toggles
(surfaced in `SettingsScreenView`), but they are inert — nothing reads them. The app
should treat YouTube and Reddit as *inactive* when their toggle is off: their existing
feeds must not aggregate, the feed list must show they are off, their swipe-update
actions must be disabled, and new feeds of that type must not be creatable.

"Not active" means **the per-source Enabled toggle is off** (decided with the user). API
key presence is *not* part of this gate — that remains a separate runtime `validate()`
concern.

Note: `redditEnabled` and `youtubeEnabled` are not in `AppSettings`'s registered
defaults, so `UserDefaults.bool` returns `false` — both sources are **off by default**
until the user enables them in Settings. This is consistent with the desired behavior.

## Scope

In scope:
- Single source-of-truth helper for "is this source active".
- Skip inactive-source feeds during aggregation (`updateAll`, `update(feed:)`,
  `forceReload(feed:)`).
- Hide inactive source types from the feed-creation type picker (but keep the current
  type visible when editing an existing feed of a now-inactive type).
- Visually mark inactive-source feeds in the Feeds list.
- Disable the per-feed "Update" and "Force reload" swipe actions for inactive-source
  feeds.
- Localized strings (`en` + `de`) for the new badge.

Out of scope:
- Already-fetched articles stay in the timeline; no retroactive hiding or deletion.
- API-key-based availability (separate, pre-existing `validate()` behavior).
- The reader pull-down refresh needs no special change — it calls `updateAll()`, which
  already skips inactive sources via the aggregation change.

## Design

### 1. `AppSettings.isSourceEnabled(_:)`

Add a `@MainActor` helper on `AppSettings`:

```swift
/// Whether the given aggregator type's content source is currently active.
/// Reddit / YouTube are gated by their per-source Enabled toggle; all other
/// types are always active.
func isSourceEnabled(_ type: AggregatorType) -> Bool {
    switch type {
    case .reddit: return redditEnabled
    case .youtube: return youtubeEnabled
    default: return true
    }
}
```

Every other component calls this so the rule lives in one place.

### 2. Aggregation skips inactive sources

`AggregationService` currently instantiates `AppSettings()` ad-hoc (AI config,
retention) and its `init` does not hold a settings reference. Add an injectable
`settings: AppSettings = AppSettings()` parameter to `init`, store it, and use it for the
source-enabled checks. Defaulting to `AppSettings()` keeps every existing call site
unchanged while letting tests pass an `AppSettings` backed by a custom `UserDefaults`
suite.

- `updateAll()`: after fetching enabled feeds, filter to
  `feeds.filter { settings.isSourceEnabled($0.type) }`. The SwiftData `#Predicate`
  can't read the toggle, so the source filter is applied in Swift after the fetch.
- `update(feed:)` and `forceReload(feed:)`: early-return `0` when
  `!settings.isSourceEnabled(feed.type)`. Do **not** write `feed.lastError` — a disabled
  source is not a fetch failure.

### 3. Feed-creation type picker

In `FeedEditorView`, the `Picker` over `AggregatorType.allCases` filters by
`settings.isSourceEnabled`, unioned with the feed's current type:

```swift
let types = AggregatorType.allCases.filter {
    settings.isSourceEnabled($0) || $0 == model.type
}
```

This prevents creating a new YouTube/Reddit feed while the source is off, yet still lets
the user open and edit an existing feed whose type is now inactive (the picker would
otherwise have no valid tag for the current selection).

`FeedEditorView` gains a `@State private var settings = AppSettings()` like the other
views.

### 4. Feeds list badge

In `FeedsView.row`, alongside the existing `!feed.enabled` "Disabled" label, add an
indicator when `!settings.isSourceEnabled(feed.type)` — a muted/secondary caption such
as "YouTube off" / "Reddit off". `FeedsView` gains
`@State private var settings = AppSettings()`.

### 5. Swipe actions disabled

In `FeedsView.leadingActions`, extend the existing `.disabled(isUpdating)` on both the
"Update" and "Force reload" buttons to
`.disabled(isUpdating || !settings.isSourceEnabled(feed.type))`. The buttons stay
visible but greyed/inert (chosen over full removal for visual consistency with the
existing `isUpdating` behavior).

### Strings

New localized strings for the badge label(s), added to
`Yana/Resources/Localizable.xcstrings` with `en` source and a `de` translation marked
`"state": "translated"`, following Apple's German localization style.

## Testing

- Unit test `AppSettings.isSourceEnabled`: returns the toggle value for `.reddit` /
  `.youtube`, `true` for a sampling of other types.
- Unit test `AggregationService`: with the source toggle off, `update(feed:)` /
  `forceReload(feed:)` for a Reddit/YouTube feed return `0` and leave `lastError` nil;
  `updateAll()` skips such feeds. Use the existing in-memory `ModelContainer` test
  helper and inject an `AppSettings` backed by a custom `UserDefaults` suite into
  `AggregationService.init`.
- Existing tests must continue to pass.

## Risks

- Both source toggles default to off, so after this change existing YouTube/Reddit feeds
  stop aggregating until the user enables the source. Acceptable and intended.
