# macOS (Catalyst) native-UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac Catalyst build feel desktop-native: right-click context menus + hover on the sidebar, a Mail-style two-pane keyboard focus model with menu-bar completeness, and session continuity (restored selection + remembered sidebar width).

**Architecture:** Three independently-shippable parts on the existing Mac surface (`Yana/Reader/Mac/`). Part A surfaces existing `TimelineModel` actions on `MacArticleRow` (no new business logic). Part B adds a SwiftUI `@FocusState` pane enum bridged into the UIKit reader (`MacReaderContainerViewController`) via `becomeFirstResponder()` + a `UIKeyCommand` escape handler. Part C reuses the already-persisted timeline anchor for selection and adds a `GeometryReader`-read sidebar width persisted through `AppSettings`.

**Tech Stack:** SwiftUI, Mac Catalyst (`#if targetEnvironment(macCatalyst)` / `UIDevice.userInterfaceIdiom == .mac`), UIKit (reader), SwiftData, `@Observable`, UserDefaults-backed `AppSettings`, Swift Testing (`import Testing`).

## Global Constraints

- **Platform floor:** iOS 26.0+; the Mac paths run under Mac Catalyst (compiles against the iOS SDK). Guard Mac-only code with `#if targetEnvironment(macCatalyst)` where it references Catalyst-only behavior; the shared views already only render on the Mac idiom via `ContentView`.
- **Strict concurrency:** Swift 6, `@MainActor` throughout the Mac UI layer (all touched types are already `@MainActor`).
- **Translations are mandatory:** every new user-facing string MUST be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state" : "translated"`. German follows Apple style (infinitive for actions, no "Du"/"Sie"), e.g. "Im Browser öffnen". Reuse existing keys where a string already exists.
- **No new dependencies.**
- **Reuse existing `TimelineModel` actions verbatim** — `toggleStar(_:)`, `copyLink(_:)`, `openWebsite(_:)`, `summarize(_:)`, `forceUpdateArticle(_:)` all already take an explicit `Article`. Resolve a row's `ArticleSummary` to an `Article` with the existing `TimelineModel.resolve(_:) -> Article?`.
- **Build/verify command (Mac Catalyst):**
  `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
  Run the built app from `/tmp/yana-mac/Build/Products/Debug-maccatalyst/Yana.app/Contents/MacOS/Yana` for manual verification.
- **Unit-test command (simulator):**
  `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
  Unit tests that assert on an empty library must launch with `-UITEST_RESET_LIBRARY` (see CLAUDE.md UI-test isolation).
- **`xcodegen generate` is only needed if files are added to the project** — new source files under an existing group covered by `project.yml` globs are picked up automatically; run `xcodegen generate` before building if you add a new file and the build can't find it.

---

## Part A — Context menus + hover

### Task 1: Sidebar row context menu

Surface the five existing `TimelineModel` actions as a right-click menu on each sidebar article row. The menu operates on **the right-clicked row's article**, resolved from the row's `ArticleSummary` — not the current selection.

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift` — `MacArticleRow` (lines 293-322) and its call site in `MacSidebarView.body` (lines 186-192).
- Modify: `Yana/Resources/Localizable.xcstrings` — add any missing menu strings with `de`.

**Interfaces:**
- Consumes: `TimelineModel.resolve(_ summary: ArticleSummary) -> Article?`, `.toggleStar(_:)`, `.openWebsite(_:)`, `.copyLink(_:)`, `.forceUpdateArticle(_:)`, `.summarize(_:)`, `.aiReady: Bool`, `.isSummarizing: Bool`; `ArticleSummary.isStarred: Bool`, `.identifier: String`.
- Produces: nothing consumed by later tasks (Task 2 edits the same `MacArticleRow` and depends on it taking a `model` parameter — introduced here).

- [ ] **Step 1: Pass the model into `MacArticleRow`**

In `MacSidebarView.body`, change the row construction (currently line 188):

```swift
ForEach(displayed) { summary in
    MacArticleRow(summary: summary, model: model)
        .listRowInsets(Self.rowInsets)
        .tag(summary.identifier)
}
```

Update `MacArticleRow`'s stored properties (currently just `let summary: ArticleSummary` at line 294):

```swift
private struct MacArticleRow: View {
    let summary: ArticleSummary
    let model: TimelineModel
```

- [ ] **Step 2: Add the context menu**

Append `.contextMenu { ... }` to `MacArticleRow`'s `body`, after the existing `.accessibilityElement(children: .combine)` (line 320):

```swift
        .accessibilityElement(children: .combine)
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder private var contextMenuItems: some View {
        Button {
            if let article = model.resolve(summary) { model.toggleStar(article) }
        } label: {
            Label(summary.isStarred ? "Unstar" : "Star",
                  systemImage: summary.isStarred ? "star.slash" : "star")
        }

        Button {
            if let article = model.resolve(summary) { model.openWebsite(article) }
        } label: { Label("Open in Browser", systemImage: "safari") }

        Button {
            if let article = model.resolve(summary) { model.copyLink(article) }
        } label: { Label("Copy link", systemImage: "link") }

        Divider()

        Button {
            if let article = model.resolve(summary) { model.forceUpdateArticle(article) }
        } label: { Label("Reload", systemImage: "arrow.trianglehead.2.clockwise") }

        if model.aiReady {
            Button {
                if let article = model.resolve(summary) { model.summarize(article) }
            } label: { Label("Summarize", systemImage: "sparkles") }
                .disabled(model.isSummarizing)
        }
    }
```

Note: `MacArticleRow` is a `private struct` in the same file, so adding a stored `model` property and referencing it compiles without further plumbing.

- [ ] **Step 3: Add/verify translations**

In `Yana/Resources/Localizable.xcstrings`, ensure each of these keys exists with a `de` translation marked `"state" : "translated"`. Reuse existing entries where present (`"Star"`, `"Unstar"`, `"Copy link"`, `"Reload"`, `"Summarize"` are used elsewhere in the Mac UI and likely already exist — do not duplicate). The one likely-new key:

- `"Open in Browser"` → `"Im Browser öffnen"`

Grep first to confirm which are missing:

Run: `grep -n '"Open in Browser"\|"Copy link"\|"Unstar"\|"Summarize"' Yana/Resources/Localizable.xcstrings`
Expected: shows which already exist; add only the missing ones.

- [ ] **Step 4: Build (Mac Catalyst)**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual verification**

Launch `/tmp/yana-mac/Build/Products/Debug-maccatalyst/Yana.app/Contents/MacOS/Yana`. Right-click a sidebar article row. Expected: a menu with Star/Unstar, Open in Browser, Copy link, a divider, Reload, and (only when an AI provider is configured) Summarize. Verify: right-clicking a **non-selected** row and choosing Star toggles *that* row's star (the yellow star marker updates), not the selected row's. Copy link then paste into any text field yields the article URL. There is no unit-test surface here (pure SwiftUI view wiring); manual verification is the gate.

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/Mac/MacRootView.swift Yana/Resources/Localizable.xcstrings
git commit -m "Add right-click context menu to Mac sidebar rows"
```

---

### Task 2: Sidebar row hover state

Give unselected rows a subtle hover fill so they read as clickable; leave the selected row's violet tint untouched.

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift` — `MacArticleRow` and its call site.

**Interfaces:**
- Consumes: `TimelineModel.selection: String?` (to know if this row is the selected one), `ArticleSummary.identifier`.
- Produces: nothing downstream.

- [ ] **Step 1: Pass selection state into the row**

In `MacSidebarView.body`, extend the row construction from Task 1:

```swift
MacArticleRow(summary: summary, model: model,
              isSelected: model.selection == summary.identifier)
```

Add the property to `MacArticleRow`:

```swift
    let summary: ArticleSummary
    let model: TimelineModel
    let isSelected: Bool
    @State private var isHovering = false
```

- [ ] **Step 2: Apply the hover background**

Insert a `.background` and `.onHover` before `.contextMenu` in `MacArticleRow.body` (the row's `HStack` already ends with `.accessibilityElement(children: .combine)`):

```swift
        .accessibilityElement(children: .combine)
        .background(hoverBackground)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
```

Add the computed background. The fill only shows when hovering AND not selected, so it never fights the source-list selection pill:

```swift
    @ViewBuilder private var hoverBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHovering && !isSelected ? Color.primary.opacity(0.06) : Color.clear)
            .padding(.horizontal, -6)
    }
```

- [ ] **Step 3: Build (Mac Catalyst)**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual verification**

Launch the built app. Move the pointer over sidebar rows. Expected: a hovered non-selected row shows a faint fill that tracks the pointer; the selected row keeps its violet pill with no double-highlight; moving off a row clears its fill. (If the `.padding(.horizontal, -6)` inset misaligns with the source-list selection insets, adjust the value — the goal is the hover fill roughly matching the selection pill bounds.)

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/Mac/MacRootView.swift
git commit -m "Add hover highlight to Mac sidebar rows"
```

---

## Part B — Two-pane keyboard focus + menu bar

> **Spike notice for the implementer:** Part B is UIKit/Catalyst *runtime* behavior with almost no unit-testable surface. Do NOT fabricate unit tests for it. The gate is manual verification on the Mac Catalyst build. Each task documents a **fallback** to ship if the full behavior proves flaky under Catalyst — take the fallback rather than sinking unbounded time into the bridge.

### Task 3: Two-pane focus model (sidebar ⇄ reader)

Focus lives in either the sidebar or the reader. Sidebar: ↑/↓ change selection (existing `List` behavior), **Return** moves focus into the reader. Reader: **Esc** returns focus to the sidebar; arrow/Space scroll if the OS provides it natively (see fallback).

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift` — add focus enum + `@FocusState`, wire sidebar List and detail.
- Modify: `Yana/Reader/Mac/MacReaderDetailView.swift` — add `isFocused`/`onEscape` inputs, first-responder + `UIKeyCommand` escape in `MacReaderContainerViewController`.

**Interfaces:**
- Consumes: existing `MacReaderDetailView(articles:index:resolveArticle:reloadToken:onRefresh:)` initializer.
- Produces: extended `MacReaderDetailView` initializer with two new parameters `isFocused: Bool` and `onEscape: () -> Void` (Task 5 does not depend on these; nothing else does).

- [ ] **Step 1: Add the focus enum and state to `MacRootView`**

At file scope in `MacRootView.swift` (near the top, after imports):

```swift
/// Which pane owns keyboard focus in the Mac window (Mail-style two-pane model).
enum MacFocusPane: Hashable { case sidebar, reader }
```

In `MacRootView`, add:

```swift
    @FocusState private var focusedPane: MacFocusPane?
```

- [ ] **Step 2: Focus the sidebar List and handle Return**

In `MacSidebarView` the List needs to participate in the parent's focus. Pass a `FocusState.Binding` down. Change `MacSidebarView` to accept it:

```swift
private struct MacSidebarView: View {
    @Bindable var model: TimelineModel
    let settings: AppSettings
    let onCreateFeed: () -> Void
    @FocusState.Binding var focusedPane: MacFocusPane?
```

On the `List` (currently ending at line 217 with `.task(id: debouncedSearch)`), add focus binding + Return handling:

```swift
        .focused($focusedPane, equals: .sidebar)
        .onKeyPress(.return) {
            guard model.selectedSummary != nil else { return .ignored }
            focusedPane = .reader
            return .handled
        }
```

Update the `MacSidebarView` construction in `MacRootView.body` (line 25) to pass the binding:

```swift
            MacSidebarView(model: model, settings: settings,
                           onCreateFeed: { openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.create) },
                           focusedPane: $focusedPane)
```

Set the initial focus once the timeline is ready, in the existing `.onAppear` (line 38):

```swift
        .onAppear {
            model.configure(modelContext: modelContext, store: store)
            model.applyTimeline()
            focusedPane = .sidebar
        }
```

- [ ] **Step 3: Extend `MacReaderDetailView` to accept focus + escape**

In `MacReaderDetailView.swift`, add two inputs (after `onRefresh`, line 17):

```swift
    var onRefresh: (() -> Void)?
    /// True when the reader pane owns keyboard focus; drives first-responder so Esc/scroll keys reach it.
    var isFocused: Bool = false
    /// Called when the user presses Esc inside the reader to hand focus back to the sidebar.
    var onEscape: () -> Void = {}
```

Wire them through `makeUIViewController` and `updateUIViewController`:

```swift
    func makeUIViewController(context: Context) -> MacReaderContainerViewController {
        let vc = MacReaderContainerViewController()
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        vc.onEscape = onEscape
        context.coordinator.lastReloadToken = reloadToken
        vc.show(articles: articles, index: index)
        return vc
    }

    func updateUIViewController(_ vc: MacReaderContainerViewController, context: Context) {
        vc.resolveArticle = resolveArticle
        vc.onRefresh = onRefresh
        vc.onEscape = onEscape
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            vc.reloadCurrent()
        }
        vc.show(articles: articles, index: index)
        if isFocused, !vc.isFirstResponder { vc.becomeFirstResponder() }
    }
```

- [ ] **Step 4: Make the container a first responder with an Esc key command**

In `MacReaderContainerViewController` (add near the other stored properties, ~line 54, and add the responder overrides):

```swift
    var onEscape: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))]
    }

    @objc private func handleEscape() { onEscape?() }
```

- [ ] **Step 5: Pass focus state from `MacRootView.detail` into the reader**

Update the `MacReaderDetailView` construction in `MacRootView.detail` (lines 55-61):

```swift
            MacReaderDetailView(
                articles: model.filteredArticles,
                index: model.currentIndex,
                resolveArticle: { model.resolve($0) },
                reloadToken: model.reloadToken,
                onRefresh: { model.triggerRefresh() },
                isFocused: focusedPane == .reader,
                onEscape: { focusedPane = .sidebar }
            )
```

- [ ] **Step 6: Build (Mac Catalyst)**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Manual verification (the gate)**

Launch the built app. With the sidebar focused (click a row, then use ↑/↓): selection moves and the reader follows. Press **Return**: focus enters the reader. Press **Esc**: focus returns to the sidebar, and ↑/↓ again move the selection. Confirm mouse-clicking a row leaves focus in the sidebar (↑/↓ still move selection afterward).

For arrow/Space **scrolling inside the reader** while it's focused: test whether the reader scrolls with ↑/↓/Space. If it does (the scroll view handles keys natively once its VC is first responder), you're done. **Fallback if it does not:** ship the reduced model — Return enters the reader (enabling Esc-to-return and any native trackpad/scroll behavior), Esc returns to the sidebar — and do NOT add bespoke key-scroll handling. Note in the commit message which model shipped. Either is an accepted outcome; do not sink unbounded time into forcing key-scroll.

- [ ] **Step 8: Commit**

```bash
git add Yana/Reader/Mac/MacRootView.swift Yana/Reader/Mac/MacReaderDetailView.swift
git commit -m "Add Mail-style two-pane keyboard focus to the Mac window"
```

---

### Task 4: Menu-bar completeness (⌘F + surfaced row actions)

Add ⌘F to focus the sidebar search field, surface the new row actions in the Article menu for discoverability, and verify (do not duplicate) the system-provided Window/Edit menus.

**Files:**
- Modify: `Yana/Reader/Mac/MacCommands.swift` — add commands.
- Modify: `Yana/Reader/Mac/MacRootView.swift` — expose a search-focus signal if ⌘F is implemented.
- Modify: `Yana/Resources/Localizable.xcstrings` — any new command titles with `de`.

**Interfaces:**
- Consumes: `@FocusedValue(\.timelineModel)` (already available), `TimelineModel.selectedArticle()`, `.resolve(_:)`, `.openWebsite(_:)`, `.copyLink(_:)`, `.forceUpdateArticle(_:)`.
- Produces: nothing downstream.

- [ ] **Step 1: Surface row actions in the Article menu**

In `MacCommands.swift`, inside `CommandMenu("Article")` (after the star/speech buttons, before the menu closes at line 55), add discoverable entries that act on the selected article. These give the actions a visible home in the menu bar (the menu bar *is* the shortcut reference):

```swift
            Divider()

            Button("Open in Browser") { if let a = model?.selectedArticle() { model?.openWebsite(a) } }
                .disabled(model?.selectedSummary == nil)
            Button("Copy link") { if let a = model?.selectedArticle() { model?.copyLink(a) } }
                .disabled(model?.selectedSummary == nil)
            Button("Reload") { if let a = model?.selectedArticle() { model?.forceUpdateArticle(a) } }
                .disabled(model?.selectedSummary == nil)
```

- [ ] **Step 2: Verify system menus before adding anything**

Build and launch the app (command below). Inspect the menu bar. Confirm whether Catalyst already provides:
- a **Window** menu (Minimize/Zoom/window list), and
- **Edit** menu Cut/Copy/Paste that work in the Settings window's text fields.

If both are present (expected under Catalyst), do NOT add duplicates. Record the finding in the commit message. Only add a `CommandGroup` for a genuinely missing standard item.

- [ ] **Step 3: Attempt ⌘F to focus sidebar search (spike, with fallback)**

Try binding the `.searchable` field to focus. Add to `MacRootView`:

```swift
    @FocusState private var searchFieldFocused: Bool
```

and on the `List` in `MacSidebarView` (needs the same `FocusState.Binding` plumbing pattern as Task 3), attach `.searchable(...).searchFocused($searchFieldFocused)` if the SwiftUI API is available in this SDK; then add a command in `MacCommands` (or a `.commands`-level button) with `.keyboardShortcut("f", modifiers: .command)` that sets the flag true via a shared signal.

**Fallback:** programmatic focus of a `.searchable` field is historically unreliable. If `searchFocused` is unavailable or ⌘F does not reliably move the caret into the search field after a few minutes of trying, **drop ⌘F entirely** — the Article-menu surfacing in Step 1 is the solid discoverability win. Do not block Part B on ⌘F.

- [ ] **Step 4: Translations**

Add `de` translations for any new command titles introduced here that don't already exist (`"Open in Browser"` added in Task 1; `"Copy link"`/`"Reload"` likely already exist). Mark each `"state" : "translated"`.

Run: `grep -n '"Open in Browser"\|"Copy link"\|"Reload"' Yana/Resources/Localizable.xcstrings`
Expected: all three present with German values.

- [ ] **Step 5: Build (Mac Catalyst)**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Manual verification**

Launch the built app. The **Article** menu shows Open in Browser / Copy link / Reload, each disabled when no article is selected and acting on the selection when enabled. If ⌘F shipped: pressing ⌘F moves the caret into the sidebar search field. Confirm Window and Edit menus behave as standard macOS menus (no duplicates added).

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/Mac/MacCommands.swift Yana/Reader/Mac/MacRootView.swift Yana/Resources/Localizable.xcstrings
git commit -m "Surface article actions in the Mac menu bar (+ optional ⌘F search focus)"
```

---

## Part C — Session state

### Task 5: Verify + complete selected-article restoration

**Selection persistence already exists** — `TimelineModel.selection`/`moveSelection(by:)` write `timelineAnchorIdentifier` + `timelineAnchorSyncUID`, and `applyTimeline()` restores them on launch (reader reopens to the same article, and the anchor even syncs across devices via `AppSettings.SyncedSettings`). This task verifies that end-to-end and fills only the residual gap: the sidebar **scrolling to** the restored row on launch (the row is selected in the binding but may be off-screen).

**Files:**
- Modify (only if the gap is confirmed): `Yana/Reader/Mac/MacRootView.swift` — `MacSidebarView`.

**Interfaces:**
- Consumes: `TimelineModel.selection`, `.currentIndex`, `.filteredArticles`, `.applyTimeline()`.
- Produces: nothing downstream.

- [ ] **Step 1: Verify current behavior**

Build and launch the app. Select an article partway down the list, quit, relaunch. Expected (already working): the reader detail reopens to that same article and the sidebar row is highlighted. Observe whether the sidebar is **scrolled so the selected row is visible**.

- [ ] **Step 2: Decide — if the selected row is already visible, skip to Step 5**

If launch already reveals the selected row, there is nothing to build; record "selection restore already complete; no scroll gap" and proceed to commit-free close (Step 5 note). If the row is selected but **off-screen**, implement Step 3.

- [ ] **Step 3: (Only if gap confirmed) Scroll to the selected row on launch**

The sidebar `List` must stay the direct child of the split-view column for source-list chrome (see the comment at `MacRootView.swift:181-185`), so a wrapping `ScrollViewReader` is not acceptable. Instead use `List`'s built-in `scrollPosition`/selection-reveal: add a one-shot that nudges the selection binding after `applyTimeline()` so the List reveals it. Concretely, in `MacSidebarView`, add:

```swift
    @State private var didRevealSelection = false
```

and a `.task` that runs once after first layout:

```swift
        .task {
            guard !didRevealSelection, let sel = model.selection else { return }
            didRevealSelection = true
            // Re-assign the same selection after the List has content so it scrolls the row into view.
            model.selection = sel
        }
```

If re-assigning the identical selection does not scroll (List treats it as a no-op), fall back to SwiftUI's `List(selection:)` + `.defaultScrollAnchor(.center)` or a `ScrollViewReader` around the List **only if** manual testing shows the source-list chrome survives it; otherwise accept "reader restores, sidebar highlight restores, scroll-to-row is best-effort" and document that limitation. Do not regress the source-list styling to force scroll.

- [ ] **Step 4: Build + manual verification**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`. Launch, select a deep row, relaunch: the sidebar scrolls to reveal the restored selection and the reader shows it.

- [ ] **Step 5: Commit (only if Step 3 changed code)**

```bash
git add Yana/Reader/Mac/MacRootView.swift
git commit -m "Reveal the restored article selection in the Mac sidebar on launch"
```

If no code changed (Step 2 short-circuit), no commit — record the finding in the plan-review notes instead.

---

### Task 6: Remember the sidebar width

Persist the user's dragged sidebar column width and restore it on next launch, clamped to the existing bounds.

**Files:**
- Create: `Yana/Reader/Mac/SidebarWidth.swift` — pure clamp helper (unit-tested).
- Create: `YanaTests/SidebarWidthTests.swift` — unit tests.
- Modify: `Yana/Models/AppSettings.swift` — add a `macSidebarWidth` key + accessor.
- Modify: `Yana/Reader/Mac/MacRootView.swift` — read via `GeometryReader`, persist debounced, apply on launch.

**Interfaces:**
- Consumes: `AppSettings` UserDefaults pattern (`access`/`withMutation`/`defaults.double(forKey:)`).
- Produces: `enum SidebarWidth { static let min/ideal/max: CGFloat; static func clamp(_:) -> CGFloat }`; `AppSettings.macSidebarWidth: Double`.

- [ ] **Step 1: Write the failing test for the clamp helper**

Create `YanaTests/SidebarWidthTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import Yana

@MainActor
struct SidebarWidthTests {
    @Test func clampBelowMinReturnsMin() {
        #expect(SidebarWidth.clamp(120) == SidebarWidth.min)
    }

    @Test func clampAboveMaxReturnsMax() {
        #expect(SidebarWidth.clamp(999) == SidebarWidth.max)
    }

    @Test func clampWithinRangeIsUnchanged() {
        #expect(SidebarWidth.clamp(400) == 400)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SidebarWidthTests`
Expected: FAIL — `SidebarWidth` is not defined.

- [ ] **Step 3: Create the helper**

Create `Yana/Reader/Mac/SidebarWidth.swift`:

```swift
import CoreGraphics

/// The Mac sidebar column's width bounds and clamping. Extracted as a pure helper so the
/// persisted-width restore (`AppSettings.macSidebarWidth`) can be validated in isolation and the
/// `NavigationSplitView` column stays within the source-list-friendly range.
enum SidebarWidth {
    static let min: CGFloat = 300
    static let ideal: CGFloat = 360
    static let max: CGFloat = 480

    /// Clamp an observed/stored width into `[min, max]`.
    static func clamp(_ width: CGFloat) -> CGFloat {
        Swift.min(Swift.max(width, min), max)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SidebarWidthTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Add the persisted setting**

In `Yana/Models/AppSettings.swift`, add a key alongside the others (near line 149-150):

```swift
        static let macSidebarWidth = "settings.macSidebarWidth"
```

Add the accessor next to the other `Double` settings (follow the exact `access`/`withMutation` pattern used by e.g. `backgroundInterval` at lines 313-315):

```swift
    /// The Mac window's remembered sidebar column width (device-local, never synced — window layout
    /// is per-device). 0 means "unset → use the ideal default".
    var macSidebarWidth: Double {
        get { access(keyPath: \.macSidebarWidth); return defaults.double(forKey: Key.macSidebarWidth) }
        set { withMutation(keyPath: \.macSidebarWidth) { defaults.set(newValue, forKey: Key.macSidebarWidth) } }
    }
```

(Do NOT add it to `SyncedSettings` — it is device-local.)

- [ ] **Step 6: Apply the stored width and capture drags in `MacRootView`**

Replace the fixed column width modifier (currently `.navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)` at line 27) with a stored-width-driven ideal, and add a `GeometryReader` background on the sidebar to observe and persist the actual width.

Compute the restore width in `MacRootView` (add a small helper property):

```swift
    private var restoredSidebarWidth: CGFloat {
        let stored = CGFloat(settings.macSidebarWidth)
        return stored > 0 ? SidebarWidth.clamp(stored) : SidebarWidth.ideal
    }
```

Change the sidebar modifier (line 27):

```swift
                .navigationSplitViewColumnWidth(
                    min: SidebarWidth.min, ideal: restoredSidebarWidth, max: SidebarWidth.max)
```

Add width capture. In `MacSidebarView`, attach a `GeometryReader` in a `.background` that debounce-writes the observed width back to `settings` (the `List` is the direct child, so read the width from an outer background rather than wrapping the List):

```swift
        .background(widthReader)
```

```swift
    @ViewBuilder private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width) { _, newWidth in
                    let clamped = SidebarWidth.clamp(newWidth)
                    // Only persist meaningful changes to avoid churn on every layout tick.
                    if abs(clamped - CGFloat(settings.macSidebarWidth)) > 1 {
                        settings.macSidebarWidth = Double(clamped)
                    }
                }
        }
    }
```

- [ ] **Step 7: Regenerate the project (new file) and build**

Run: `xcodegen generate`
Then: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Manual verification**

Launch the built app. Drag the sidebar divider to a wider (or narrower) width within bounds. Quit and relaunch. Expected: the sidebar reopens at approximately the width you left it (clamped to 300–480), not the 360 default. Dragging to the extremes clamps rather than overshooting.

- [ ] **Step 9: Run the full unit suite to confirm no regression**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SidebarWidthTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Yana/Reader/Mac/SidebarWidth.swift YanaTests/SidebarWidthTests.swift Yana/Models/AppSettings.swift Yana/Reader/Mac/MacRootView.swift
git commit -m "Remember the Mac sidebar width across launches"
```

---

## Final: documentation + full verification

### Task 7: Docs + full test pass

**Files:**
- Modify: `CLAUDE.md` — extend the Mac Catalyst windowing section with the new affordances.

- [ ] **Step 1: Update CLAUDE.md**

In the "Mac Catalyst windowing" bullet under Architecture, add a sentence noting: sidebar rows now have a right-click context menu (star, open in browser, copy link, reload, summarize) and hover highlighting; the window uses a Mail-style two-pane keyboard focus model (Return enters the reader, Esc returns to the sidebar) with article actions surfaced in the Article menu; and the sidebar width is remembered across launches (`AppSettings.macSidebarWidth`, device-local via `SidebarWidth`).

- [ ] **Step 2: Run the full unit + UI test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests pass (the iOS surfaces are untouched; the new `SidebarWidthTests` pass). If a cold-launch/Mach-308 flake appears, shut down simulators and retry — it is not a real failure (see memory).

- [ ] **Step 3: Final Mac Catalyst build**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Document Mac native-UX improvements"
```

---

## Self-Review Notes (author)

- **Spec coverage:** A1 context menu → Task 1; A2 hover → Task 2; B1/B2 focus bridge → Task 3; B3 menu bar (⌘F, surfaced actions, verify Window/Edit) → Task 4; C1 selected-article restore → Task 5 (narrowed: persistence already exists, only scroll-to-row is potentially new — flagged to user); C2 sidebar width → Task 6. Docs → Task 7.
- **Deviation from spec, surfaced to user:** C1's persistence + reader restore already ships in `TimelineModel`/`applyTimeline()`; Task 5 is verify-first and only fills the sidebar scroll-reveal gap if it exists, rather than reimplementing existing behavior.
- **Honesty on tests:** Parts A and B and C1 are SwiftUI/UIKit runtime wiring with no meaningful unit-test surface — those tasks gate on Mac Catalyst manual verification. The one genuinely pure unit (width clamping) is TDD'd in Task 6. This is deliberate, not an omission.
- **Fallbacks documented** for the two spike risks: reader key-scroll (Task 3 Step 7) and ⌘F search focus (Task 4 Step 3).
- **Type consistency:** `MacArticleRow` gains `model`/`isSelected` across Tasks 1–2; `MacReaderDetailView` gains `isFocused`/`onEscape` in Task 3; `MacFocusPane`, `SidebarWidth`, and `AppSettings.macSidebarWidth` names are used consistently across their tasks.
