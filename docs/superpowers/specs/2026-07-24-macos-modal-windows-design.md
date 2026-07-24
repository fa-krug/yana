# macOS: Modals → Separate Windows

**Date:** 2026-07-24
**Status:** Design approved, pending spec review
**Scope:** Mac Catalyst build only. iPhone/iPad keep today's sheets & full-screen cover.

## Problem

On the Mac (Mac Catalyst) build, three flows are presented as overlays that feel wrong on
a desktop: onboarding (`WelcomeView`, a `.fullScreenCover`), the feed editor
(`FeedEditorView`, a `.sheet`), and Settings (`SettingsScreenView`, a `.sheet`). We want each
to be a real, independent macOS window. Settings additionally gets a two-pane
sidebar+content layout (System-Settings style) split into seven panes.

## Goals

1. On Mac, Welcome, the Feed editor, and Settings each open as a separate resizable window
   (real title bar, Window-menu entry, ⌘W to close, scene restoration).
2. Mac Settings becomes a `NavigationSplitView`: a sidebar of
   **General · Reader · Feeds · Tags · Integrations · AI · About**, with the selected pane's
   content in the detail.
3. iPhone/iPad behavior is unchanged.

Non-goals: converting nested/secondary modals (create-tag sheet, OPML export dialog, the
feed-source search picker inside the feed editor) into windows — those stay as sheets over
their parent window. No generic "New Window" command.

## Approach

**SwiftUI multi-scene**, gated `#if targetEnvironment(macCatalyst)`. New scenes are added to
`YanaApp.body`; views open/close them via `@Environment(\.openWindow)` /
`@Environment(\.dismiss)` (and `dismissWindow` where needed). `UIApplicationSupportsMultipleScenes`
is already `true` in `Info-iOS.plist`, so no Info.plist change is required.

Rejected alternative: UIKit `requestSceneSessionActivation` with manual scene delegates and a
scene manifest — far more plumbing, redundant with SwiftUI scenes on Catalyst.

### Key consequence: closures → shared state

Child window scenes are constructed by the `App`, not by the presenting view, so they cannot
capture the closures the current sheets pass. Each modal's closure-driven coordination is
replaced with shared observable state / existing singletons:

| Modal | Today (closure) | New (window) |
|---|---|---|
| Welcome | `onFinish` sets `hasCompletedOnboarding` + `appState.showWelcome = false` | Welcome window sets `hasCompletedOnboarding = true`, then `dismiss()`. Presentation is driven by opening/closing the window, not `appState.showWelcome`. |
| Feed editor (create) | `onCreate`/`createFeed` closure fetches the new feed | Feed-editor window performs the insert/save/fetch inline via `AggregationService` + `ConfigSyncService.requestPush()`, then `dismiss()`. |
| Settings | `onRestartOnboarding` closes settings + re-shows welcome | Settings' "Show Welcome Again" calls `openWindow(.welcome)` + `dismiss()`. |

## Components

### 1. Window identity (`Yana/Reader/Mac/WindowID.swift`, new)

```swift
enum WindowID {
    static let settings = "settings"
    static let welcome = "welcome"
    static let feedEditor = "feed-editor"
}

/// Which feed the editor window edits. `.create` = a brand-new feed.
enum FeedEditorTarget: Codable, Hashable {
    case create
    case edit(PersistentIdentifier)
}
```

`PersistentIdentifier` is `Codable` + `Hashable`, so it is a valid `WindowGroup(for:)` value.

### 2. Scenes in `YanaApp.body` (Mac-only)

Added after the existing `WindowGroup`, inside `#if targetEnvironment(macCatalyst)`:

```swift
Window("Settings", id: WindowID.settings) {
    MacSettingsWindow(appState: appState)
        .environment(articleStore)
}
.modelContainer(AppContainer.shared)
.defaultSize(width: 720, height: 620)

Window("Welcome to Yana", id: WindowID.welcome) {
    WelcomeWindowRoot(appState: appState)
        .environment(articleStore)
}
.modelContainer(AppContainer.shared)

WindowGroup(id: WindowID.feedEditor, for: FeedEditorTarget.self) { $target in
    FeedEditorWindowRoot(target: target ?? .create)
        .environment(articleStore)
}
.modelContainer(AppContainer.shared)
.defaultSize(width: 560, height: 640)
```

Each scene re-injects `.modelContainer(AppContainer.shared)` and `.environment(articleStore)`
(scenes do not inherit the primary window's environment). `appState` is the same `@State`
instance held by `YanaApp`, shared into every scene.

### 3. Welcome window (`Yana/Reader/Mac/WelcomeWindowRoot.swift`, new)

Thin wrapper that owns onboarding completion (no `onFinish` from a parent):

- Renders `WelcomeView(onFinish: …)` where `onFinish` sets `settings.hasCompletedOnboarding = true`
  and calls `dismiss()`.
- Defensive restoration guard: if `hasCompletedOnboarding` is already `true` when the scene
  appears (e.g. macOS restored the window on relaunch), it calls `dismiss()` immediately so a
  completed user never re-sees onboarding.
- `WelcomeView`'s own internal "add first feed" step keeps its in-window sheet (nested modal,
  out of scope per the top-level-only decision).

Launch trigger: on Mac, `ContentView.onAppear` (which today sets `appState.showWelcome`) instead
calls `openWindow(id: WindowID.welcome)` when `!hasCompletedOnboarding && !skipOnboarding`. The
`-UITEST_*` suppression logic is preserved. `MacRootView`'s `.fullScreenCover(showWelcome)` is
removed.

### 4. Feed editor window (`Yana/Reader/Mac/FeedEditorWindowRoot.swift`, new)

- Input: `FeedEditorTarget`.
- `.edit(id)` → resolve the `Feed` from `AppContainer.shared.mainContext` by
  `PersistentIdentifier`; if it no longer exists, `dismiss()`.
- `.create` → pass `feed: nil`.
- Wraps `FeedEditorView` in a `NavigationStack` (it uses toolbar + a nested search sheet).
- On successful create, runs the fetch that the old `onCreate` closures ran:
  `ConfigSyncService.shared.requestPush()`, and if the new feed is enabled, an
  `AggregationService(context:).update(feed:)` via `UpdateActivity.shared`. Then `dismiss()`.
- On save/cancel it `dismiss()`es its own window.

`FeedEditorView`'s existing `onCreate` closure parameter is retained for the iOS call sites
(`FeedsView`, `WelcomeView`); the Mac window supplies its own closure that does the fetch.

### 5. Mac Settings window (`Yana/Reader/Mac/MacSettingsWindow.swift`, new)

`NavigationSplitView` with a sidebar `List(selection:)` over a `SettingsPane` enum and a detail
that switches on the selection:

```swift
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, feeds, tags, integrations, ai, about
}
```

- Sidebar rows: localized title + SF Symbol per pane; default selection `.general`.
- Detail per pane wraps content in a `Form` (and a `NavigationStack` for `.feeds`/`.tags`,
  which use `NavigationLink` for row editing). Detail column min width ~ 460.
- `.feeds` → `FeedsView`; `.tags` → `TagsView`; other panes compose the reusable section views
  (below).
- Pushes config on window close: `.onDisappear { ConfigSyncService.shared.requestPush() }`
  (mirrors today's `SettingsScreenView.onDisappear`).

### 6. Reusable settings sections (`Yana/Views/Config/Settings/`, new)

`SettingsScreenView` is decomposed so iOS and Mac share one source of truth per group. Each unit
is a small `View` that emits its own `Section` and owns only its own state:

- `ReaderSettingsSection` — text size, font, preview, system browser, read-aloud voice.
- `RedditSettingsSection` — Reddit toggle + credentials + Test (owns its keychain `@State`).
- `YouTubeSettingsSection` — YouTube toggle + key + Test.
- `NotificationsSettingsSection` — notifications toggle + denied alert.
- `AIProviderSettingsSection` — provider picker + per-provider config + Test (keeps
  `settings.aiSection` accessibility id).
- `AITuningSettingsSection` — temperature, max tokens, advanced knobs.
- `LibrarySettingsSection` — retention, background refresh.
- `ICloudSyncSettingsSection` — iCloud toggle + passive-device + errors.
- `AboutSettingsSection` — links + "Show Welcome Again" (keeps `settings.showWelcome` id). On
  Mac it uses `openWindow(.welcome)` + closes settings; on iOS it keeps the existing
  `onRestartOnboarding` behavior.

Shared credential-test helper (`Yana/Views/Config/Settings/CredentialTestControls.swift`, new):
the `TestStatus` enum, the `testControls(...)` button+status view, and the `runTest(...)` runner
are extracted here so Reddit/YouTube/AI sections reuse them.

**iOS `SettingsScreenView`** becomes a thin `Form` composing these units in the *current order*
(organize links → Reader → Reddit → YouTube → Notifications → AI provider → AI tuning → Library →
iCloud → About) so it stays visually identical. Its Feeds/Tags `NavigationLink`s (with
`settings.feeds` id) are unchanged.

**Mac panes** group the same units:
- General = Notifications + Library + iCloud
- Reader = ReaderSettingsSection
- Integrations = Reddit + YouTube
- AI = AIProvider + AITuning
- About = AboutSettingsSection

### 7. Command / focus cleanups

- `MacRootView`: remove `.sheet(showingSettings)`, `.sheet(showingCreateFeed)`,
  `.fullScreenCover(showWelcome)`, the `showingSettings`/`showingCreateFeed` state, and the
  `.focusedSceneValue(\.settingsOpen, …)`. Settings menu button and empty-state "Add Feed" call
  `openWindow(...)`. `MacReaderDetailView`/sidebar "Add Feed" → `openWindow(.feedEditor, value: .create)`.
- `MacCommands`: the ⌘, Settings item calls `openWindow(WindowID.settings)`. Remove the
  `settingsOpen` `FocusedValue` + `SettingsOpenKey` and simplify `navDisabled` to `model == nil`
  — when the Settings window is key, the reader scene publishes no `timelineModel`, so
  Article-navigation commands disable on their own. `CommandGroup(replacing: .newItem) {}` stays.

## Data flow

- Feed creation from the Feeds pane or empty state → `openWindow(.feedEditor, value: .create)` →
  window inserts/saves/fetches → SwiftData save → `ArticleStore` re-index → the reader window's
  `TimelineModel` updates via its existing `store.summaries` observer. No cross-window callback.
- Editing a feed → `openWindow(.feedEditor, value: .edit(id))` → edits saved to the shared
  context. `WindowGroup(for:)` gives each distinct feed its own window; re-opening the same
  target focuses the existing window.
- Onboarding completion → `hasCompletedOnboarding` flips (UserDefaults, observed by any
  `AppSettings` instance) → welcome window dismisses.

## Error / edge handling

- Feed-editor `.edit(id)` where the feed was deleted meanwhile → dismiss.
- Welcome window restored on relaunch after onboarding done → self-dismiss.
- Last window closed on Mac: unchanged — the multiple-scenes flag already keeps the app running;
  reopen from the Dock.
- Two settings windows: `Window(id:)` is single-instance, so ⌘, focuses the existing one.

## Testing

- Unit (`YanaTests`): `FeedEditorTarget` Codable/Hashable round-trip; `SettingsPane.allCases`
  count/ids stable; `WindowID` constants.
- Existing UI/screenshot tests: unaffected — screenshots are iPhone-only (6.9″), and the iOS
  `SettingsScreenView` keeps its structure and accessibility ids (`settings.feeds`,
  `settings.aiSection`, `settings.showWelcome`).
- Manual (Mac build): each window opens/focuses/closes (⌘W), scene restoration behaves, feed
  create/edit reflects in the reader, onboarding completes and dismisses.

## Files

New:
- `Yana/Reader/Mac/WindowID.swift`
- `Yana/Reader/Mac/WelcomeWindowRoot.swift`
- `Yana/Reader/Mac/FeedEditorWindowRoot.swift`
- `Yana/Reader/Mac/MacSettingsWindow.swift`
- `Yana/Views/Config/Settings/CredentialTestControls.swift`
- `Yana/Views/Config/Settings/*SettingsSection.swift` (nine section views)

Changed:
- `Yana/YanaApp.swift` (new Mac scenes)
- `Yana/ContentView.swift` (Mac launch opens welcome window)
- `Yana/Reader/Mac/MacRootView.swift` (drop sheets/cover; openWindow)
- `Yana/Reader/Mac/MacReaderDetailView.swift` (if it hosts an "Add Feed" action)
- `Yana/Reader/Mac/MacCommands.swift` (⌘, openWindow; drop settingsOpen)
- `Yana/Views/Config/SettingsScreenView.swift` (compose extracted sections)
- `Yana/Views/Config/FeedsView.swift` (Mac: openWindow for create/edit; iOS unchanged)
- `Yana/Reader/Mac/TimelineModel.swift` (if `createFeed` becomes unused on Mac)
- `Localizable.xcstrings` (any new user-facing strings, EN + DE)

## Localization

New user-facing strings (pane titles if not already present, window titles) get EN + DE entries
marked `translated`, German in Apple infinitive style.
