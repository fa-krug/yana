# macOS (Catalyst) native-UX improvements

**Date:** 2026-07-25
**Status:** Design approved, pending spec review

## Goal

Make the Mac Catalyst build feel like a desktop app rather than an iOS app running
in a window. The Mac build already has a real foundation — a permanent two-column
`NavigationSplitView` (`MacRootView`), a menu bar (`MacCommands`), separate floating
windows for Settings/Welcome/Feed-editor, a System-Settings-style two-pane Settings
window, and an LRU-cached reader that prewarms neighbors. This work closes the
"still reads as iOS" gaps: no right-click, no hover feedback, incomplete keyboard
focus, and no session continuity.

This is **one cohesive spec** delivered as **three independently-shippable parts**,
in order of ascending risk: **A → B → C**.

- **A** — Native polish: sidebar context menus + hover states. Pure surfacing of
  existing actions; lowest risk.
- **B** — Two-pane keyboard focus model + menu-bar completeness. Carries the one
  real technical risk (UIKit ↔ SwiftUI focus bridging).
- **C** — Session state: restore selected article + sidebar width. Small.

Non-goals (explicitly excluded per brainstorming): drag & drop, toolbar
customization, an inspector panel, Settings-pane persistence, and explicit
window-frame persistence (Catalyst restores window frames automatically).

## Relevant existing code

- `Yana/Reader/Mac/MacRootView.swift` — the two-column split view. `MacSidebarView`
  (~149), `MacArticleRow` (~293), `MacFilterBar` (~235), toolbar (~66-130),
  `focusedSceneValue(\.timelineModel)` (~36).
- `Yana/Reader/Mac/TimelineModel.swift` — shared selection/filter/actions.
  `moveSelection(by:)` (~76), article actions star/copyLink/openWebsite/summarize/
  refresh (~148-217). All context-menu items reuse these.
- `Yana/Reader/Mac/MacReaderDetailView.swift` — `UIViewControllerRepresentable`
  wrapping `MacReaderContainerViewController` → cached `ReaderBlockViewController`
  pages. `allowsFullscreen: false` (~114).
- `Yana/Reader/Mac/MacCommands.swift` — `YanaCommands` menu bar; reads
  `@FocusedValue(\.timelineModel)` / `\.readerSpeech`; Article menu (~32-55).
- `Yana/Models/AppSettings.swift` — preferences store; already holds
  `timelineAnchorUID` (persisted and iCloud-synced).

## Part A — Context menus + hover

### A1. Sidebar row context menu

Add `.contextMenu` to `MacArticleRow` (`MacRootView.swift:293`). Items, each calling
an existing `TimelineModel` action against **the right-clicked row's article** (not
necessarily the current selection):

| Item | Action |
|------|--------|
| Star / Unstar | `TimelineModel` star toggle (label reflects current starred state) |
| Open in Browser | `TimelineModel` open-website (honors the "Use System Browser" setting) |
| Copy Link | `TimelineModel` copy-link |
| Reload | `TimelineModel` force-reload single article |
| Summarize | `TimelineModel` summarize — **shown only when AI is configured**, matching the toolbar More menu's existing gate |

`TimelineModel`'s action methods currently operate on the selected article. If an
action assumes `selectedArticle`, extend it to take an explicit article argument
(the row already has its article), keeping the selection-based call sites working via
a default. No new business logic — this is surfacing only.

All user-facing strings (menu titles) get `de` translations in
`Localizable.xcstrings`, each `"state": "translated"`. Several labels ("Copy Link",
"Open in Browser", "Reload", "Summarize", "Star"/"Unstar") likely already exist from
the toolbar/menu bar — reuse those keys.

### A2. Hover states

`.onHover` on `MacArticleRow` applies a subtle background fill behind **unselected**
rows on hover; selected rows keep the existing violet tint (unchanged). This is the
affordance that signals a row is clickable. Toolbar buttons already receive system
hover treatment under Catalyst — no change there.

## Part B — Two-pane keyboard focus + menu bar

### B1. Focus model (Mail-style)

A `@FocusState` enum (`.sidebar` / `.reader`) owned by `MacRootView`.

- **Sidebar focused:** ↑/↓ change selection (existing `List` behavior); **Return**
  moves focus into the reader.
- **Reader focused:** ↑/↓ and **Space** scroll the current article; **Esc** returns
  focus to the sidebar.
- Clicking a row with the mouse keeps focus in the sidebar, so the user can keep
  arrowing through the list.

### B2. The technical risk (bridge)

The reader detail is UIKit (`MacReaderDetailView` → `ReaderBlockViewController`), so
SwiftUI `@FocusState` does not cross into it cleanly. The reader side needs UIKit key
handling — `UIKeyCommand` / first-responder wiring — inside the reader container,
bridged back to the SwiftUI focus enum through the representable's coordinator:

- Reader becomes first responder when the focus enum is `.reader`; resigns when
  `.sidebar`.
- Reader-side `UIKeyCommand`s: Esc → tell coordinator to set focus `.sidebar`;
  arrows/Space → scroll (may already be native scroll-view behavior once the reader
  is first responder — verify before adding explicit handlers).
- Sidebar-side Return → set focus `.reader`.

**Checkpoint / fallback:** prototype this bidirectional bridge first. If robust
arrow/Space capture inside the reader proves flaky under Catalyst, ship the reduced
model — **Return = focus reader, Esc = focus sidebar**, relying on the scroll view's
own key handling for scrolling — which is still a clear improvement. The
implementation plan must treat "does the full bridge work?" as an explicit decision
point, not assume success.

### B3. Menu bar

- **⌘F** focuses the sidebar search field. Add as a command in `MacCommands`
  targeting a focus/search binding published from `MacRootView`.
- Surface the new row actions (Open in Browser, Copy Link, Reload) in the existing
  **Article** menu so they're discoverable and their shortcuts (where they have them)
  are visible — the menu bar *is* the shortcut reference.
- **Verify before adding:** Catalyst auto-provides a standard Window menu and the
  Edit-menu copy/paste items for text fields (used in Settings). Do **not** duplicate
  system-provided menus — only add what's genuinely missing after checking the
  running app.

## Part C — Session state

### C1. Selected article restoration

Reuse the existing `timelineAnchorUID` (already persisted, already iCloud-synced)
rather than a new key:

- On Mac selection change, write the selected article's UID to `timelineAnchorUID`.
- On launch, restore the sidebar selection from `timelineAnchorUID` (resolve UID →
  article in the loaded `ArticleStore` index; if absent, fall back to the current
  default — first/top article).

Benefit: desktop and phone converge on the same "where I left off" article via the
sync layer, with no new synced field.

### C2. Sidebar width restoration

`NavigationSplitView` does not report the user's dragged column width back to
SwiftUI, so:

- Read the sidebar's actual width via a `GeometryReader` inside the sidebar content.
- Debounce-persist it to `@AppStorage` (a new local, non-synced key — window layout
  is device-specific).
- On next launch, feed the stored value back as the preferred column width
  (`.navigationSplitViewColumnWidth`), clamped to the existing min/ideal/max
  (300/360/480).

## Testing

- **Part A:** unit-test that the extended `TimelineModel` actions operate on an
  explicitly-passed article (star toggle, copy link, reload target) independent of
  the current selection. Context-menu presence/gating (Summarize hidden when AI
  unconfigured) verified via the view's action wiring.
- **Part B:** the focus bridge is UIKit/Catalyst-runtime behavior that unit tests
  can't fully cover; verify manually on the Mac build (Return enters reader, Esc
  returns, arrows behave per whichever model ships). Unit-test any pure state
  (focus-enum transitions) that can be factored out of the view.
- **Part C:** unit-test selection→`timelineAnchorUID` write and launch restore
  (UID present → selects it; UID missing → default). Sidebar-width persistence
  (clamp to min/max, round-trip through `@AppStorage`) unit-tested on the pure
  read/clamp/store logic.
- Follow the repo's UI-test isolation rules (`-UITEST_RESET_LIBRARY`,
  `scrollToSettingsRow`) if any UI test is added.
- All new user-facing strings get `de` translations marked `translated`.

## Sequencing

Ship A, then B, then C — each independently mergeable. A de-risks the surface, B is
the one part with a real spike (the focus bridge, with a defined fallback), C is a
small continuity win.
