# macOS Version (Mac Catalyst) — Design

**Date:** 2026-07-22

## Summary

Ship Yana on the Mac by enabling **Mac Catalyst** on the existing `Yana` target. The Mac build is
"pretty much identical" to iOS with one structural change: the **article list is permanent in a
sidebar** rather than a sheet. The window is a two-column `NavigationSplitView` — sidebar =
`ArticleListView` (search + tag filter), detail = the reader for the selected article.

Everything below the UI layer is reused unchanged: `Models/`, `Services/`, `Aggregators/`,
SwiftData, CloudKit config sync, Keychain, and SwiftSoup parsing are all platform-agnostic. The
only meaningful new code is a Mac-specific window shell and a thin reader-detail host; the reader's
expensive parts (block rendering, speech, image/video viewers) are reused as-is.

## Motivation

The full reader stack (`ArticleBlockView`, `Block`/`BlockParser`, `ReaderSpeechController`,
`ReaderImageViewerViewController`, `ReaderVideoPlayerViewController`) and all aggregation/sync logic
are already written and battle-tested. Mac Catalyst runs UIKit natively, so the cheapest path to a
real Mac app reuses that stack wholesale rather than rewriting the reader in AppKit. The single
iOS-shaped assumption that does not survive on the desktop is the **swipe-pager navigation model** —
once a Mac window shows the article list permanently, the list becomes the primary navigation and
the horizontal `UIPageViewController` is redundant. This design keeps the pager on iOS and replaces
it on Mac with a selection-driven single-article detail pane, sharing the page renderer between both.

## Decisions (locked)

- **Tech:** Mac Catalyst (not native AppKit). Reuse the UIKit reader.
- **Layout:** two-column `NavigationSplitView` (list → reader). Three-column is a future enhancement.
- **Reader model (Option C):** detail pane hosts a single `ReaderBlockViewController` for the
  selected article; the sidebar `List(selection:)` is the navigation. Neighbor articles are
  **prewarmed** so selection changes are instant.
- **Transition:** instant hard-swap on selection change (no cross-dissolve).
- **Read-aloud:** keeps playing the article it was started on; changing selection does **not** stop
  or switch narration. It switches only when the user explicitly starts read-aloud on another article.
- **Tag filter:** lives at the **top of the sidebar** (always visible), not a popover/sheet.
- **Windows:** single main library window + the standard **Settings window (⌘,)**. No multi-window.
- **macOS floor:** **macOS 26 (Tahoe) only** — mirrors the iOS 26 deployment target. No back-deploy.

## Current State (baseline, iOS)

- `project.yml`: `Yana` target is `platform: iOS`, `TARGETED_DEVICE_FAMILY: "1"` (iPhone),
  `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: true`, deployment target iOS 26.0.
- `ContentView` renders `ReaderScreen` directly (no split view); the article list is a `.sheet`
  (`appState.showArticleList`), settings a `.sheet`, tag filter a `.sheet` (`TagFilterView`).
- `ReaderScreen` owns the filtered timeline, position memory (`timelineAnchorIdentifier` +
  `appState.currentIndex`), refresh, star, summarize, and the sheets. It hands the timeline to
  `ReaderHostView` (a `UIViewControllerRepresentable`) which wraps
  `UINavigationController → ReaderArticleViewController` (a `UIPageViewController` pager).
- Each pager page is a `ReaderBlockViewController` — a self-contained single-article view hosting
  `ArticleBlockView`, owning link/image/video handling. It carries three pager-only concessions:
  `startsWithFastText` (first-paint deferral), `hideBarsTapZonesActive` + the tap zones (tap-to-hide
  fullscreen). These go dormant on Mac.
- `PrewarmPlan` is pure (neighbor-index computation) and unit-tested; `ReaderImageCache` warms images.
- `BackgroundRefreshManager` uses `BGAppRefreshTask` (registered/scheduled in the `AppDelegate`).
- Chrome lives in the reader's nav bar + bottom toolbar + overflow (`ReaderMenuBuilder`):
  filter, show-list, settings, star, refresh (pull-down), and per-article Reload / Copy link /
  Summarize / Go to feed.

## Design

### 1. Project / build (`project.yml`)

Enable Catalyst on the `Yana` target rather than adding a second target (keeps one source set):

- `SUPPORTS_MACCATALYST: YES`
- `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO` (keep `de.fa-krug.Yana` across platforms so
  the same `iCloud.de.fa-krug.Yana` CloudKit container and Keychain are shared → config sync
  iPhone↔Mac works with no new code).
- `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO` once Catalyst is on (they are mutually exclusive).
- Mac idiom: `MacCatalyst` optimized-for-Mac interface (`UIDesignRequiresCompatibility: NO`).
- Mac entitlements file (App Sandbox on, `com.apple.security.network.client`, iCloud services
  container `iCloud.de.fa-krug.Yana`, keychain-access-group, `aps-environment` for CloudKit silent
  pushes). Mirror the iOS entitlements' iCloud/push entries.
- App icon: add the macOS icon slots to the existing `AppIcon` asset (layered icon already exists).
- Fastlane / screenshots / Pages site remain iOS-only; no changes.

### 2. Platform-split root (`ContentView`)

Branch the root on `UIDevice.current.userInterfaceIdiom == .mac` (Catalyst reports `.mac` under the
Mac idiom):

```
if idiom == .mac {
    MacRootView(appState:)          // NavigationSplitView shell (new)
} else {
    ReaderScreen(appState:)         // unchanged iOS pager surface
}
```

Onboarding (`WelcomeView` full-screen cover) is reused as-is; it presents fine over the split view.

### 3. `MacRootView` (new) — the two-column shell

A `NavigationSplitView`:

- **Sidebar**
  - Top: the **tag filter** control (reuses the same `AppSettings`-backed
    `disabledTagNames`/`includeUntagged`/`disabledFeedNames` state that `TagFilterView` edits —
    rendered inline instead of in a sheet).
  - Below: `ArticleListView` bound to a `selection` of the article identifier. Selection is the
    single source of truth and maps to `appState.currentIndex` / `timelineAnchorIdentifier` — so the
    existing position-memory logic (`saveAnchor`, `reanchorToCurrentArticle`, `openArticle`) is
    reused directly. `List(selection:)` gives ↑/↓ article navigation for free.
  - Search field is the list's existing `.searchable`.
- **Detail**
  - `MacReaderDetailView` (a `UIViewControllerRepresentable`, new) hosting the reader-detail host
    below. Shows a placeholder ("No Article Selected") when selection is nil, and the empty-state
    "create feed" shortcut (reusing `onCreateFeed`) when the library is empty.
- **Toolbar** (window): refresh (⌘R), star toggle, summarize, reload-this-article, copy link,
  read-aloud, and a sidebar-toggle. These reuse `ReaderScreen`'s existing callbacks
  (`triggerRefresh`, `toggleStar`, `summarize`, `forceUpdateArticle`, `copyLink`) verbatim —
  `MacRootView` owns the same handlers `ReaderScreen` does (extract the shared handler logic so it
  is not duplicated; see §7).
- **Menu bar** (`.commands`): mirror the toolbar actions with shortcuts — ⌘R update all, ⌘F focus
  search, star, next/previous article (↓/↑ already work in the list; add explicit menu items),
  Settings (⌘,).

### 4. Reader detail host (new) — Option C

`MacReaderDetailView: UIViewControllerRepresentable` wraps a small container VC,
`MacReaderContainerViewController`, that shows exactly one `ReaderBlockViewController` at a time and
swaps its child when the selected identifier changes.

Key mechanism — **the prewarm cache is also the scroll-memory cache**:

- Keep an **LRU cache of `ReaderBlockViewController` keyed by article identifier** (small, e.g. 5).
- On selection change: if the target VC is cached, bring it forward instantly (its scroll offset is
  preserved); else build it (`resolveArticle` → full `Article` with `[Block]` body) and insert.
- After a swap, call `PrewarmPlan.indices(current:count:radius:direction:)` (ported verbatim) to
  decide which **neighbor** identifiers to build-into-cache ahead of time and to warm via
  `ReaderImageCache`. "Prewarm index N" is reinterpreted as "instantiate + cache VC N" instead of
  "warm pager page N."
- Swap is instant (no animation), matching the locked decision.
- The pager-only concessions on `ReaderBlockViewController` go dormant: pass
  `allowsFullscreen: false`, never activate tap zones, leave `startsWithFastText` false (no swipe
  animation to protect; the LRU + prewarm cover fast ↓-key travel).

`ReaderArticleViewController` (the `UIPageViewController`) and `ReaderHostView` are **not used** on
Mac. They stay unchanged for iOS.

### 5. Read-aloud continuity

`ReaderSpeechController` already keeps playing across app backgrounding and lock. On Mac we simply
**do not tie speech to selection** — the container VC does not stop/restart speech when the child VC
swaps. Speech is owned above the swappable child (at the `MacReaderContainerViewController` level or
the existing shared controller) and bound to the article the user pressed play on. Pressing
read-aloud on a newly selected article explicitly switches it.

### 6. Background refresh on Mac

`BGAppRefreshTask` is unavailable under Catalyst. Add a Mac path in `BackgroundRefreshManager`:

- **On launch / on window focus:** run `updateAll()` (respecting the intake window/cap) — cheap and
  covers the common "reopen the app" case.
- **While running:** an `NSBackgroundActivityScheduler` (or a foreground `Timer`) fires at
  `AppSettings.backgroundInterval`, calling the same `updateAll()` handler and posting the same
  new-article notification when enabled.
- The iOS `BGAppRefreshTask` registration is compiled/guarded so it is not attempted on Mac.

### 7. Shared handler extraction

`ReaderScreen` currently owns `triggerRefresh`, `toggleStar`, `summarize`, `forceUpdateArticle`,
`copyLink`, `saveAnchor`, `reanchorToCurrentArticle`, `openArticle`, `recomputeFilter`,
`applyTimeline`. To avoid duplicating these in `MacRootView`, extract the timeline/action logic into
a shared `@MainActor @Observable` view-model (e.g. `TimelineModel`) that both `ReaderScreen` (iOS)
and `MacRootView` (Mac) drive. This is an internal refactor with no behavior change on iOS.

## Touch-idiom → Mac substitutions

| iOS interaction | Mac |
|---|---|
| Horizontal swipe between articles | List selection + ↑/↓ arrow keys |
| Pull-to-refresh | Toolbar button + ⌘R |
| Tap title bar to hide toolbars (fullscreen) | Retired (dormant tap zones) |
| Show-list button | Retired (list always visible) / sidebar toggle |
| Tag filter sheet | Sidebar-top filter control |
| Settings sheet | Settings window (⌘,) |
| Image pinch-to-zoom / swipe-down dismiss | Scroll/trackpad zoom / Esc + close button |
| Haptics | No-op on Mac |
| Face ID (planned biometric) | Touch ID / password (LocalAuthentication) |

## Non-goals

- Native AppKit reader rewrite.
- Three-column (Feeds/Tags source list) layout — future enhancement.
- Multiple library windows.
- Back-deploying below macOS 26.
- Any change to iOS behavior beyond the internal handler extraction in §7.

## Free wins

- **CloudKit config sync** (`ConfigSyncService`/`StarredRegistry`) already syncs feeds, tags,
  settings, starred marks, and API keys via the shared container + iCloud Keychain. A same-bundle-id
  Mac build joins that sync with no new code; article bodies re-fetch per device as designed.
- The whole aggregation/parsing/AI/notification stack is platform-agnostic and untouched.

## Risks / open items

- **`.mac` idiom checks:** audit existing `userInterfaceIdiom == .phone` uses (e.g. the
  fullscreen-hint toast in `ReaderScreen.onAppear`) so Mac takes the right branch.
- **Entitlements/signing:** Catalyst needs its own provisioning; verify the iCloud container and
  push entitlement resolve for the Mac bundle in App Store Connect (same app record, Mac checkbox).
- **Window state restoration:** confirm selection + per-article scroll survive window
  close/reopen within a session (LRU cache is in-memory; `timelineAnchorIdentifier` persists the
  selection across launches as on iOS).
- **First-paint under fast ↓-key travel:** validate the LRU radius; bump `PrewarmPlan` radius if
  holding the down arrow outpaces the cache.

## Rollout

1. `project.yml` Catalyst flags + Mac entitlements + Mac app-icon slots; regenerate project, confirm
   it builds for "My Mac (Mac Catalyst)".
2. Extract `TimelineModel` (internal refactor; iOS unchanged; tests stay green).
3. `MacRootView` split-view shell + sidebar (list + tag filter) wired to `TimelineModel`.
4. `MacReaderDetailView` + `MacReaderContainerViewController` with the LRU/prewarm cache.
5. Window toolbar + `.commands` menu bar + Settings window.
6. Mac background-refresh path in `BackgroundRefreshManager`.
7. Touch-idiom substitutions + `.mac` idiom audit.
```
