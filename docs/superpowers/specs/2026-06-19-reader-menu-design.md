# Reader Menu Design

**Date:** 2026-06-19

## Summary

Add a top-right overflow menu (`UIMenu`) to the reader's navigation bar with four
actions: **Force update**, **Copy link**, **Summarize**, and **Go to feed**. All
existing toolbar entries (Filter, Star, Library, Share, Open in browser) remain
unchanged. The menu is additive and is rebuilt against the current article each time
it opens, so its conditional items reflect the article in view.

## Motivation

The reader currently exposes only direct, single-action bar buttons. Several useful
actions either have no entry point (force update is buried in pull-to-refresh; there
is no on-demand summarization) or require navigating away (reaching a feed's settings
means opening the Library hub and drilling into the Feeds list). A compact overflow
menu surfaces these without crowding the existing toolbar.

## Placement

- A new menu button using the SF Symbol `ellipsis.circle` is added to the top-right
  navigation bar as the **outermost (rightmost)** item.
- Resulting right-side order, from the edge inward: **⋯ menu · Library · Star**.
- The menu is a native `UIMenu` attached to a `UIBarButtonItem` on
  `ReaderArticleViewController`.
- Existing items are untouched: Filter (nav left), Star + Library (nav right),
  Share + Open-in-browser (bottom toolbar), title-tap full-screen toggle.

## Menu Items

Listed top to bottom as they appear in the menu.

1. **Force update** — symbol `arrow.clockwise`. Always present. Invokes the same path
   as pull-to-refresh: `onRefresh` → `UpdateActivity.shared.restart()` →
   `AggregationService.updateAll()`.

2. **Copy link** — symbol `link`. Copies the current article's `url` to
   `UIPasteboard.general`. Present whenever `url` is non-empty; omitted otherwise.

3. **Summarize** — symbol `sparkles`. Present **only when AI is ready**:
   - a cloud provider is selected (`AppSettings.activeAIProvider != .none`) **and** a
     non-empty API key exists in the Keychain for it, **or**
   - Apple Intelligence reports `.available`.

   Always re-runs, overwriting any existing summary. See the Summarize flow below.

4. **Go to feed** — symbol `dot.radiowaves.up.forward`. Presents `FeedEditorView` for
   the current article's `feed` as its own sheet. **Omitted entirely when `feed` is
   nil** (e.g. an article orphaned after its feed was deleted).

Because items 3 and 4 are conditional on the current article and on AI state, the menu
is rebuilt each time it is presented (and kept in sync on page change), not built once.

## Summarize Flow

There is currently no on-demand summarization path — summarization only happens inside
the aggregation pipeline, gated by each feed's `AIOptions.summarize` toggle.

- Add a reusable method on `AggregationService`, e.g. `summarize(_ article:)`, that:
  1. Builds an `AIConfig` via the existing `makeAIConfig`.
  2. Selects the processor with the same logic as `currentAIProcessor()`
     (`AIProcessor` for cloud providers, `AppleIntelligenceProcessor` for on-device).
  3. Runs it with a forced `AIOptions(summarize: true)` so it works even on feeds whose
     own summarize toggle is off.
  4. Writes the returned `summary` onto the `Article` and saves the model context.
- **Progress feedback:** reuse the nav-bar activity indicator (already wired via
  `setRefreshing`) or an equivalent transient state while the request runs; the
  Summarize item is disabled mid-run.
- **Re-render:** after the summary is saved, reload the current page's `WKWebView` so
  `ArticleRenderer.composeBody()` re-composes with the new summary block (the same kind
  of reload already used on text-size changes).
- **Failure:** although the item only appears when AI is "ready," the network/model
  call can still fail. Surface a brief error alert on failure; leave the article
  unchanged.

## Data Flow / Wiring

- `ReaderArticleViewController` holds the current article and owns the menu. It builds
  the `UIMenu` from the current article + AI-readiness state.
- New callbacks bubble up, mirroring the existing `onToggleStar` / `onShowSettings` /
  `onRefresh` pattern: `onCopyLink`, `onSummarize`, `onGoToFeed`.
- These thread through `ReaderHostView` → `ReaderScreen` to their handlers.
- `AppState` gains a `feedToEdit: Feed?` field to drive the feed-editor sheet, matching
  the existing `showSettings` / `showFilter` booleans. `ReaderScreen` presents
  `FeedEditorView(feed:)` (wrapped in a `NavigationStack`) as a sheet when `feedToEdit`
  is set.

## Units & Responsibilities

- **`ReaderArticleViewController`** — owns the menu button and assembles the `UIMenu`
  per presentation; routes taps to callbacks. Knows nothing about AI internals beyond a
  passed-in "AI ready" boolean and the current article.
- **`AggregationService.summarize(_:)`** — single-article, on-demand summarization;
  reuses `makeAIConfig` and processor selection. Pure service method, independently
  testable.
- **`ReaderScreen` / `ReaderHostView`** — translate UIKit callbacks into SwiftData
  writes (copy link, trigger summarize), `AppState` mutations (feed sheet), and refresh.
- **`AppState`** — adds `feedToEdit: Feed?` for sheet presentation.

## Localization

New user-facing strings must be added to `Yana/Resources/Localizable.xcstrings` with
German (`de`) translations marked `"state": "translated"`, following Apple's style
(infinitive for actions, no Du/Sie):

- "Force update", "Copy link", "Summarize", "Go to feed"
- A summarize-failure alert title/message.

## Testing

- Unit-test `AggregationService.summarize(_:)`: with a stub AI client, a forced
  `summarize: true` produces a non-empty `summary` on the article regardless of the
  feed's own `AIOptions`; on a thrown error the article's existing content/summary is
  left unchanged.
- Verify menu assembly logic: Summarize omitted when AI not ready; Go-to-feed omitted
  when `feed` is nil; Copy link omitted when `url` empty. Factor menu-item-visibility
  into a small pure helper if needed for testability.

## Out of Scope

- Quick text-size / theme controls in the menu.
- Duplicating Share or Open-in-browser into the menu.
- Re-running improve-writing or translate on demand (only summarize is on-demand here).
- Changing the existing toolbar layout or the pull-to-refresh gesture.
