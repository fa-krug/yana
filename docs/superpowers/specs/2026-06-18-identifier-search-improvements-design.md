# Identifier Search Improvements — Design

Date: 2026-06-18

## Goal

Improve the subreddit / YouTube channel picker (`IdentifierSearchView`) used when
configuring a Reddit or YouTube feed. Today it only searches when the user presses
enter, shows results as a single plain text line per row, and uses a text "Cancel"
button. Make it preload an initial list, search live (debounced) as the user types,
match the styling of the app's other lists, and replace the text Cancel button with
an icon.

## Current State

- `Yana/Views/Config/IdentifierSearchView.swift` — `IdentifierSearchModel` (testable,
  injectable Reddit/YouTube search closures) + `IdentifierSearchView` (a `NavigationStack`
  with a `List(model.rows)`, `.searchable`, `.onSubmit(of: .search)`, and a
  `ContentUnavailableView` overlay).
- Rows are `Button { Text(row.label) }`, where `label` is a prebuilt string such as
  `"r/NintendoSwitch — Nintendo Switch … (7937468 subs)"`.
- Search fires **only** on submit.
- `RedditClient.searchSubreddits` → `subreddits/search.json?q=…&limit=10`.
- `YouTubeClient.searchChannels` → `search.list?type=channel&maxResults=10` then
  `channels.list` for snippets.
- Cancel is a text toolbar button (`Button("Cancel")`).

## Changes

### 1. Preload an initial list on open

- **Reddit:** on appear, fetch popular subreddits and show them as the initial list.
  Add `RedditClient.popularSubreddits(credentials:userAgent:fetch:)` hitting
  `https://oauth.reddit.com/subreddits/popular.json?limit=25&raw_json=1`, reusing the
  existing `RedditSubredditListing` decoder and `authorizedGET`. Returns
  `[RedditSubredditResult]` (same mapping/filter as `searchSubreddits`).
- **YouTube:** the YouTube Data API has no query-less "popular channels" endpoint, so
  there is no list to preload. YouTube opens showing the "Search" prompt
  (`ContentUnavailableView`) and populates once the user types (up to 25 entries).

### 2. Debounced live search as you type

- `IdentifierSearchModel` gains a debounced entry point. The view binds
  `.onChange(of: query)`; on each change the model cancels any in-flight search task,
  sleeps ~300 ms (`Task.sleep`), then runs the search. `Task.isCancelled` is checked
  after the sleep and after the await so superseded keystrokes don't clobber newer
  results. `.onSubmit(of: .search)` remains as an immediate (un-debounced) trigger.
- Clearing the query (empty/whitespace) restores the preloaded popular list (Reddit)
  or the prompt (YouTube) — it does not leave stale results on screen.
- Result caps raised to 25: Reddit `searchSubreddits` and YouTube `searchChannels`
  both use `limit`/`maxResults` = 25 (Reddit popular is already 25).

### 3. Styling to match the app's other lists

- `IdentifierSearchRow` carries structured fields instead of one prebuilt `label`:
  `value` (saved identifier), `title` (primary line), `subtitle` (secondary line).
- Rows become a two-line layout mirroring `ArticleListView` / `FeedsView`
  (12 pt / 4 pt spacing): primary line in `.headline`, secondary in `.caption` +
  `.secondary`.
  - **Subreddit:** primary `r/NintendoSwitch`; secondary combines **both** the title
    text and a compactly formatted subscriber count, e.g.
    `Nintendo Switch — News, Updates… · 7.9M subscribers`. Subscriber counts are
    formatted with a number formatter (e.g. `7.9M`, `411K`) rather than the raw
    integer.
  - **YouTube:** primary channel title; secondary the `@handle` (falling back to the
    channel ID when no handle exists, preserving current behavior).

### 4. Cancel button → icon

- Replace the text toolbar button with an icon button:
  `Button { dismiss() } label: { Image(systemName: "xmark") }` in the
  `.cancellationAction` slot, with `.accessibilityLabel("Cancel")` for VoiceOver.

### 5. Localization

- Any new/changed user-facing strings (compact subscriber count format such as
  `"%@ subscribers"`, the YouTube search prompt text, accessibility label) are added to
  `Yana/Resources/Localizable.xcstrings` with German translations marked
  `"state" : "translated"`, following Apple's German localization style.

## Testing

- `IdentifierSearchModel` keeps injectable Reddit/YouTube search closures and gains an
  injectable preload closure so preload + debounce result mapping stay hermetic.
- Unit tests (Swift Testing, `@MainActor`):
  - preload populates `rows` from the popular closure on open (Reddit).
  - typing maps search results into structured rows (title/subtitle correct).
  - clearing the query restores the preloaded list.
  - subscriber-count compacting (`7937468 → 7.9M`, `411321 → 411K`, small numbers
    unchanged) via a pure helper.
  - YouTube row maps handle vs. channel-ID fallback.

## Out of Scope

- No change to how `IdentifierSearchView` is presented from `FeedEditorView`.
- No change to the saved identifier semantics (subreddit display name / channel ID).
- No offline caching of search results.
