# macOS Modal Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the Mac (Mac Catalyst) build, present Welcome, the Feed editor, and Settings as separate native windows, with Settings restructured as a two-pane sidebar (General · Reader · Feeds · Tags · Integrations · AI · About).

**Architecture:** Add macCatalyst-gated SwiftUI scenes to `YanaApp.body` (`Window` for Settings & Welcome, `WindowGroup(for:)` for the Feed editor). Views open/close them via `@Environment(\.openWindow)` / `@Environment(\.dismiss)`. Because scenes are built by the `App`, not the presenting view, the modals' closures are replaced by shared observable state (`AppState`, `AppSettings`, existing singletons). Settings' one big `Form` is decomposed into reusable per-group section views that iOS composes in the current order and the Mac split view groups into panes.

**Tech Stack:** SwiftUI (iOS 26 / Mac Catalyst), SwiftData, Swift 6 strict concurrency, Swift Testing (`import Testing`) for unit tests.

## Global Constraints

- Platform: iOS 26.0+; Mac via Mac Catalyst (native Mac idiom). Window work is **Mac-only** (`#if targetEnvironment(macCatalyst)`); iPhone/iPad keep today's sheets & `.fullScreenCover` unchanged.
- Swift 6 strict concurrency; UI types are `@MainActor`.
- All new user-facing strings MUST be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state" : "translated"` (German = Apple infinitive style).
- Preserve accessibility identifiers `settings.feeds`, `settings.aiSection`, `settings.showWelcome` (used by UI/screenshot tests).
- `UIApplicationSupportsMultipleScenes` is already `true` in `Yana/Info-iOS.plist` — do not touch it.
- No unit test can assert Catalyst window/toolbar rendering; those tasks verify via **build succeeds** + explicit manual-check notes. Build command: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build`.

---

### Task 1: Window identity, feed-editor target, settings-pane enum

**Files:**
- Create: `Yana/Reader/Mac/WindowID.swift`
- Test: `YanaTests/WindowIdentityTests.swift`

**Interfaces:**
- Produces:
  - `enum WindowID { static let settings = "settings"; static let welcome = "welcome"; static let feedEditor = "feed-editor" }`
  - `enum FeedEditorTarget: Codable, Hashable { case create; case edit(PersistentIdentifier) }`
  - `enum SettingsPane: String, CaseIterable, Identifiable { case general, reader, feeds, tags, integrations, ai, about; var id: String { rawValue } }` — plus `title: LocalizedStringKey` and `systemImage: String`.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/WindowIdentityTests.swift`:

```swift
import SwiftData
import Testing
@testable import Yana

@MainActor
struct WindowIdentityTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Tag.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test func feedEditorTargetCreateRoundTrips() throws {
        let data = try JSONEncoder().encode(FeedEditorTarget.create)
        let decoded = try JSONDecoder().decode(FeedEditorTarget.self, from: data)
        #expect(decoded == .create)
    }

    @Test func feedEditorTargetEditDistinguishesFeeds() throws {
        let container = try makeContainer()
        let a = Feed(name: "A", aggregatorType: .feedContent, identifier: "a://")
        let b = Feed(name: "B", aggregatorType: .feedContent, identifier: "b://")
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        try container.mainContext.save()

        #expect(FeedEditorTarget.edit(a.persistentModelID) == .edit(a.persistentModelID))
        #expect(FeedEditorTarget.edit(a.persistentModelID) != .edit(b.persistentModelID))
        #expect(FeedEditorTarget.edit(a.persistentModelID) != .create)
    }

    @Test func settingsPanesAreStableAndOrdered() {
        #expect(SettingsPane.allCases == [.general, .reader, .feeds, .tags, .integrations, .ai, .about])
        #expect(SettingsPane.ai.rawValue == "ai")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/WindowIdentityTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'FeedEditorTarget' in scope` / `SettingsPane`.

- [ ] **Step 3: Create `WindowID.swift`**

```swift
import SwiftData
import SwiftUI

/// Stable identifiers for the Mac (Mac Catalyst) auxiliary windows opened via `openWindow`.
enum WindowID {
    static let settings = "settings"
    static let welcome = "welcome"
    static let feedEditor = "feed-editor"
}

/// Which feed the feed-editor window edits. `.create` = a brand-new feed.
/// `PersistentIdentifier` is `Codable` + `Hashable`, so this is a valid `WindowGroup(for:)` value:
/// each distinct feed gets its own editor window, and every `.create` shares one.
enum FeedEditorTarget: Codable, Hashable {
    case create
    case edit(PersistentIdentifier)
}

/// The panes of the Mac two-pane Settings window sidebar, in display order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, feeds, tags, integrations, ai, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .reader: "Reader"
        case .feeds: "Feeds"
        case .tags: "Tags"
        case .integrations: "Integrations"
        case .ai: "AI"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .reader: "textformat"
        case .feeds: "list.bullet.rectangle"
        case .tags: "tag"
        case .integrations: "puzzlepiece.extension"
        case .ai: "sparkles"
        case .about: "info.circle"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/WindowIdentityTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/Mac/WindowID.swift YanaTests/WindowIdentityTests.swift
git commit -m "Add Mac window identifiers, feed-editor target, and settings-pane enum"
```

---

### Task 2: Shared credential-test control

Extract the duplicated credential-test UI so the split-out Integrations/AI sections (Task 3) reuse one implementation.

**Files:**
- Create: `Yana/Views/Config/Settings/CredentialTestControls.swift`
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (remove the moved `TestStatus`, keep everything else compiling)

**Interfaces:**
- Produces:
  - `enum TestStatus: Equatable { case idle, testing, valid, invalid(String) }` (moved here verbatim from `SettingsScreenView.swift:5-10`).
  - `struct CredentialTestControls: View` — `init(status: TestStatus, disabled: Bool, onClear: @escaping () -> Void, action: @escaping () -> Void)`. Renders the Test button + inline status rows (the body of `SettingsScreenView.testControls`, `SettingsScreenView.swift:562-595`).
  - `enum CredentialTest { static func run(_ setter: @escaping (TestStatus) -> Void, _ op: @escaping () async -> CredentialTestError?) }` — the body of `SettingsScreenView.runTest` (`SettingsScreenView.swift:598-605`).

- [ ] **Step 1: Create `CredentialTestControls.swift`**

```swift
import SwiftUI

/// Per-section credential-test state shown in Settings.
enum TestStatus: Equatable {
    case idle
    case testing
    case valid
    case invalid(String)   // localized message
}

/// A "Test" button plus an inline status row, shared by every credential section
/// (Reddit, YouTube, each AI provider).
struct CredentialTestControls: View {
    let status: TestStatus
    let disabled: Bool
    let onClear: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Test")
                if status == .testing {
                    Spacer()
                    Text("Testing…").foregroundStyle(.secondary)
                    ProgressView()
                }
            }
        }
        .disabled(disabled || status == .testing)

        switch status {
        case .idle, .testing:
            EmptyView()
        case .valid:
            Label("Credentials valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            HStack {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("Clear", action: onClear).buttonStyle(.borderless)
            }
        }
    }
}

/// Runs an async credential test, threading its status through `setter`.
enum CredentialTest {
    static func run(_ setter: @escaping (TestStatus) -> Void,
                    _ op: @escaping () async -> CredentialTestError?) {
        setter(.testing)
        Task {
            let error = await op()
            setter(error.map { .invalid($0.localizedMessage) } ?? .valid)
        }
    }
}
```

- [ ] **Step 2: Remove the now-duplicated `TestStatus` from `SettingsScreenView.swift`**

Delete lines `SettingsScreenView.swift:4-10` (the `/// Per-section…` comment through the `enum TestStatus { … }` closing brace). Leave `SettingsScreenView`'s private `testControls`/`runTest` methods in place for now — Task 3 removes them. `TestStatus` now resolves from the new file (same module).

- [ ] **Step 3: Build to verify green**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/Settings/CredentialTestControls.swift Yana/Views/Config/SettingsScreenView.swift
git commit -m "Extract shared CredentialTestControls from settings"
```

---

### Task 3: Decompose settings into reusable section views

Split each settings group into its own `View` that owns only its state, then recompose `SettingsScreenView` (iOS) from them **in the current visual order** so iOS is byte-for-byte unchanged on screen.

**Files:**
- Create (in `Yana/Views/Config/Settings/`): `ReaderSettingsSection.swift`, `RedditSettingsSection.swift`, `YouTubeSettingsSection.swift`, `NotificationsSettingsSection.swift`, `AIProviderSettingsSection.swift`, `AITuningSettingsSection.swift`, `LibrarySettingsSection.swift`, `ICloudSyncSettingsSection.swift`, `AboutSettingsSection.swift`
- Modify: `Yana/Views/Config/SettingsScreenView.swift`

**Interfaces:**
- Produces nine `View` structs, each rendering exactly one `Section` group (or two, where noted). Each owns its own `@State private var settings = AppSettings()` and, where applicable, its own Keychain `@State` + `TestStatus` + an `onAppear` loader. They render `CredentialTestControls`/`CredentialTest.run` from Task 2.
  - `AboutSettingsSection` takes `var onRestartOnboarding: () -> Void = {}` (iOS behavior); Task 7 adds the Mac open-window path.
  - `AIProviderSettingsSection` keeps `.accessibilityIdentifier("settings.aiSection")` on the provider picker; `AboutSettingsSection` keeps `.accessibilityIdentifier("settings.showWelcome")` on the welcome button.
- Consumes: `CredentialTestControls`, `CredentialTest.run` (Task 2); `TestStatus` (Task 2).

Each section is a **verbatim move** of the corresponding `SettingsScreenView` computed property into a new `struct`'s `body`, wrapped so it owns the state that property used. Source line ranges (pre-edit):

| New file | Move from `SettingsScreenView.swift` | Owns state |
|---|---|---|
| `ReaderSettingsSection` | `readerSection` (102-159) + `installedVoices` (162-166) + `voiceLabel` (169-172) | `settings` |
| `RedditSettingsSection` | `redditSection` (176-208) | `settings`, `redditClientID`, `redditClientSecret`, `redditStatus` |
| `YouTubeSettingsSection` | `youtubeSection` (210-230) | `settings`, `youtubeKey`, `youtubeStatus` |
| `NotificationsSettingsSection` | `notificationsSection` (234-254) + the denied `.alert` (71-75) | `settings`, `showNotificationDeniedAlert` |
| `AIProviderSettingsSection` | `aiProviderSection` (258-270) + `providerConfig` (274-405) + `appleIntelligenceStatus` (407-418) | `settings`, all provider keys, all provider `TestStatus`es |
| `AITuningSettingsSection` | `aiKnobsSection` (420-455) | `settings` |
| `LibrarySettingsSection` | `librarySection` (457-473) | `settings` |
| `ICloudSyncSettingsSection` | `iCloudSyncSection` (477-528) | `settings` |
| `AboutSettingsSection` | `aboutSection` (532-560) | `settings` |

Mechanical transform for every move:
1. Replace calls to `testControls(status:disabled:onClear:action:)` with `CredentialTestControls(status:disabled:onClear:action:)`.
2. Replace `runTest(setter, op)` with `CredentialTest.run(setter, op)`.
3. Each section that reads a Keychain secret gets an `.onAppear { load() }` that loads only ITS keys (the relevant subset of `loadSecrets`, `SettingsScreenView.swift:607-624`). The `-UITEST_SCREENSHOTS` provider-default hook (619-623) goes into `AIProviderSettingsSection.onAppear`.

- [ ] **Step 1: Create the nine section files**

For each, scaffold as below (shown for two representative cases; apply the transform table to the rest).

`ReaderSettingsSection.swift`:

```swift
import AVFoundation
import SwiftUI

/// Reader preferences: text size, font, live preview, system-browser toggle, read-aloud voice.
struct ReaderSettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        // MOVE the body of SettingsScreenView.readerSection (lines 102-159) here verbatim.
    }

    // MOVE installedVoices (162-166) and voiceLabel (169-172) here verbatim.
}
```

`RedditSettingsSection.swift`:

```swift
import SwiftUI

/// Reddit source: enable toggle, client id/secret, user agent, credential test.
struct RedditSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var redditClientID = ""
    @State private var redditClientSecret = ""
    @State private var redditStatus: TestStatus = .idle

    var body: some View {
        // MOVE the body of SettingsScreenView.redditSection (176-208) here verbatim,
        // swapping testControls(...) -> CredentialTestControls(...) and runTest(...) -> CredentialTest.run(...).
        // ... existing Section content ...
    }

    private func load() {
        redditClientID = KeychainService.loadAPIKey(for: .redditClientID) ?? ""
        redditClientSecret = KeychainService.loadAPIKey(for: .redditClientSecret) ?? ""
    }
}
```

Add `.onAppear { load() }` to the `Section` in each credential section (Reddit, YouTube, AIProvider). Apply the same pattern to the remaining files per the table. For `NotificationsSettingsSection`, attach the denied `.alert(...)` (71-75) to its `Section`. For `AboutSettingsSection`, add `var onRestartOnboarding: () -> Void = {}` and keep the existing button behavior (`settings.hasCompletedOnboarding = false; onRestartOnboarding()`), dropping the `dismiss()` call (the host handles dismissal).

- [ ] **Step 2: Recompose `SettingsScreenView` (iOS) from the sections**

Replace the whole `struct SettingsScreenView` body and its now-moved private members with a thin composition that preserves the current order and the Feeds/Tags navigation links. New file contents:

```swift
import SwiftUI

/// iOS settings: a single scrolling Form. Feeds/Tags push detail screens; every other group is a
/// reusable section view shared with the Mac two-pane settings window.
struct SettingsScreenView: View {
    var onRestartOnboarding: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            organizeSection
            ReaderSettingsSection()
            RedditSettingsSection()
            YouTubeSettingsSection()
            NotificationsSettingsSection()
            AIProviderSettingsSection()
            AITuningSettingsSection()
            LibrarySettingsSection()
            ICloudSyncSettingsSection()
            AboutSettingsSection(onRestartOnboarding: {
                onRestartOnboarding()
                dismiss()
            })
        }
        .toggleStyle(.switch)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
        }
        .onDisappear { ConfigSyncService.shared.requestPush() }
    }

    private var organizeSection: some View {
        Section {
            NavigationLink { FeedsView() } label: {
                Label("Feeds", systemImage: "list.bullet.rectangle").labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.feeds")
            NavigationLink { TagsView() } label: {
                Label("Tags", systemImage: "tag").labelStyle(.tintedIcon(.pink))
            }
        } footer: {
            Text("Manage your feeds and the tags applied to articles.")
        }
    }
}
```

- [ ] **Step 3: Run the existing settings UI test path (iOS) + build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Manual check note: on iOS the Settings screen must look and behave exactly as before (same section order, `settings.feeds`/`settings.aiSection`/`settings.showWelcome` ids present).

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/Settings/ Yana/Views/Config/SettingsScreenView.swift
git commit -m "Decompose settings into reusable per-group section views"
```

---

### Task 4: Mac two-pane Settings window view

**Files:**
- Create: `Yana/Reader/Mac/MacSettingsWindow.swift`

**Interfaces:**
- Consumes: `SettingsPane` (Task 1); the nine section views + `FeedsView`/`TagsView` (Task 3); `AppState`.
- Produces: `struct MacSettingsWindow: View` — `init(appState: AppState)`. Selize-selection sidebar + per-pane detail. About pane's restart-onboarding wiring is stubbed here and completed in Task 7.

- [ ] **Step 1: Create `MacSettingsWindow.swift`**

```swift
import SwiftUI

/// The Mac Settings window: a System-Settings-style two-pane layout. The sidebar lists the
/// `SettingsPane`s; the detail shows the selected pane. Each pane reuses the same section views as
/// the iOS Form, regrouped for the desktop.
struct MacSettingsWindow: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.systemImage).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Settings")
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 460, ideal: 520)
        }
        .toggleStyle(.switch)
        .frame(minWidth: 700, minHeight: 560)
        .onDisappear { ConfigSyncService.shared.requestPush() }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:
            Form {
                NotificationsSettingsSection()
                LibrarySettingsSection()
                ICloudSyncSettingsSection()
            }
        case .reader:
            Form { ReaderSettingsSection() }
        case .feeds:
            NavigationStack { FeedsView() }
        case .tags:
            NavigationStack { TagsView() }
        case .integrations:
            Form {
                RedditSettingsSection()
                YouTubeSettingsSection()
            }
        case .ai:
            Form {
                AIProviderSettingsSection()
                AITuningSettingsSection()
            }
        case .about:
            Form {
                AboutSettingsSection(onRestartOnboarding: {
                    // Completed in Task 7: open the Welcome window, then close Settings.
                })
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify green (view compiles, not yet wired to a scene)**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Yana/Reader/Mac/MacSettingsWindow.swift
git commit -m "Add Mac two-pane Settings window view"
```

---

### Task 5: Wire the Settings window scene and open it

Add the Settings `Window` scene, open it from the toolbar/menu/⌘,, remove the old settings sheet, and drop the now-unneeded `settingsOpen` focused value.

**Files:**
- Modify: `Yana/YanaApp.swift` (add scene)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (remove settings sheet + `settingsOpen`; openWindow)
- Modify: `Yana/Reader/Mac/MacCommands.swift` (⌘, openWindow; remove `settingsOpen`)

**Interfaces:**
- Consumes: `MacSettingsWindow` (Task 4), `WindowID` (Task 1).

- [ ] **Step 1: Add the Settings scene to `YanaApp.body`**

In `Yana/YanaApp.swift`, inside the existing `#if targetEnvironment(macCatalyst)` region that holds `.commands { YanaCommands() }` (lines 138-143), add a scene after the `WindowGroup { … }.modelContainer(...)` block (i.e. after line 137) but still inside `var body: some Scene`. Wrap the new scene in its own `#if targetEnvironment(macCatalyst)`:

```swift
        #if targetEnvironment(macCatalyst)
        Window("Settings", id: WindowID.settings) {
            MacSettingsWindow(appState: appState)
                .environment(articleStore)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 720, height: 620)
        #endif
```

- [ ] **Step 2: Open Settings from `MacRootView` via `openWindow`**

In `Yana/Reader/Mac/MacRootView.swift`:
- Add `@Environment(\.openWindow) private var openWindow` near the other environment properties (after line 11).
- Delete `@State private var showingSettings = false` (line 17).
- Delete `.focusedSceneValue(\.settingsOpen, showingSettings)` (line 39).
- Delete the `.sheet(isPresented: $showingSettings) { … }` block (lines 45-53).
- In the `Menu` (line 130-131), change the Settings button action:

```swift
                Button { openWindow(id: WindowID.settings) } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
```

- [ ] **Step 3: Update `MacCommands.swift` — ⌘, opens the window, drop `settingsOpen`**

In `Yana/Reader/Mac/MacCommands.swift`:
- Delete the `settingsOpen` `FocusedValues` computed property (lines 14-18) and the `SettingsOpenKey` struct (line 22).
- Delete `@FocusedValue(\.settingsOpen) private var settingsOpen` (line 31).
- Change `navDisabled` (line 34) to: `private var navDisabled: Bool { model == nil }`.

The ⌘, Settings item lives in `MacRootView`'s Menu (Step 2); no Settings command is added to `YanaCommands`. Leave `CommandGroup(replacing: .newItem) {}` as-is.

- [ ] **Step 4: Build to verify green**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Manual check note: on the Mac, ⌘, (and the More-menu Settings item) open a separate two-pane Settings window; the reader's ⌘↑/⌘↓ do nothing while that window is key.

- [ ] **Step 5: Commit**

```bash
git add Yana/YanaApp.swift Yana/Reader/Mac/MacRootView.swift Yana/Reader/Mac/MacCommands.swift
git commit -m "Present macOS Settings as a separate two-pane window"
```

---

### Task 6: Feed-editor window (create + edit)

**Files:**
- Create: `Yana/Reader/Mac/FeedEditorWindowRoot.swift`
- Modify: `Yana/YanaApp.swift` (add `WindowGroup(for:)` scene)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (empty-state "Add Feed" → openWindow; remove create-feed sheet)
- Modify: `Yana/Views/Config/FeedsView.swift` (Mac: create/edit via window; iOS unchanged)
- Modify: `Yana/Reader/Mac/TimelineModel.swift` (remove now-unused `createFeed`)

**Interfaces:**
- Consumes: `FeedEditorTarget`, `WindowID` (Task 1); `FeedEditorView` (existing).
- Produces: `struct FeedEditorWindowRoot: View` — `init(target: FeedEditorTarget)`. Resolves `.edit(id)` → `Feed` (dismiss if missing); `.create` → `feed: nil` and runs the post-create fetch inline.

- [ ] **Step 1: Create `FeedEditorWindowRoot.swift`**

```swift
import SwiftData
import SwiftUI

/// Hosts `FeedEditorView` in its own Mac window. Replaces the sheet's create/edit closures: on
/// create it inserts (via FeedEditorView) then fetches the new feed itself; on edit it resolves the
/// feed from the shared context. Dismisses its own window when the editor finishes.
struct FeedEditorWindowRoot: View {
    let target: FeedEditorTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    @ViewBuilder private var content: some View {
        switch target {
        case .create:
            FeedEditorView(feed: nil) { newFeed in
                ConfigSyncService.shared.requestPush()
                if newFeed.enabled {
                    UpdateActivity.shared.restart {
                        _ = await AggregationService(context: AppContainer.shared.mainContext)
                            .update(feed: newFeed)
                    }
                }
                dismiss()
            }
        case .edit(let id):
            if let feed = AppContainer.shared.mainContext.model(for: id) as? Feed {
                FeedEditorView(feed: feed)
            } else {
                // The feed was deleted before this window resolved it — nothing to edit.
                Color.clear.onAppear { dismiss() }
            }
        }
    }
}
```

Note: `FeedEditorView` already calls `dismiss()` internally on save/cancel, which closes this window (its `@Environment(\.dismiss)` targets the window scene). The create closure's `dismiss()` is a belt-and-suspenders close after the fetch kicks off.

- [ ] **Step 2: Add the feed-editor scene to `YanaApp.body`**

In `Yana/YanaApp.swift`, inside the same `#if targetEnvironment(macCatalyst)` scene region (next to the Settings `Window` from Task 5):

```swift
        WindowGroup(id: WindowID.feedEditor, for: FeedEditorTarget.self) { $target in
            FeedEditorWindowRoot(target: target ?? .create)
                .environment(articleStore)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 560, height: 640)
```

- [ ] **Step 3: `MacRootView` — open the editor window instead of the sheet**

In `Yana/Reader/Mac/MacRootView.swift`:
- Delete `@State private var showingCreateFeed = false` (line 16).
- Delete the `.sheet(isPresented: $showingCreateFeed) { … }` block (lines 40-44).
- Replace the two `onCreateFeed`/`showingCreateFeed = true` call sites (the `MacSidebarView(... onCreateFeed:)` at line 27 and `MacEmptyLibraryView(onCreateFeed:)` at line 76) so they call `openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.create)`. `openWindow` is already available from Task 5, Step 2.

Concretely, line 27 becomes:
```swift
            MacSidebarView(model: model, settings: settings,
                           onCreateFeed: { openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.create) })
```
and line 76 becomes:
```swift
            MacEmptyLibraryView(onCreateFeed: { openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.create) })
```

- [ ] **Step 4: `FeedsView` — Mac create/edit via window, iOS unchanged**

In `Yana/Views/Config/FeedsView.swift`, add `@Environment(\.openWindow) private var openWindow` (after line 8). Then branch the create action and the row:

Replace the `showingCreateFeed = true` toolbar button action (lines 95-99) and the `.sheet(isPresented: $showingCreateFeed) { … }` (lines 125-134) so that:
- On Mac Catalyst the "+" button calls `openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.create)` and there is **no** `showingCreateFeed` sheet.
- On iOS the current button + sheet are unchanged.

Wrap with `#if targetEnvironment(macCatalyst)`:

```swift
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    #if targetEnvironment(macCatalyst)
                    openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.create)
                    #else
                    showingCreateFeed = true
                    #endif
                } label: { Image(systemName: "plus") }
            }
```

and gate the sheet:

```swift
        #if !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                FeedEditorView(feed: nil) { newFeed in
                    ConfigSyncService.shared.requestPush()
                    guard newFeed.enabled else { return }
                    updateOne(newFeed)
                }
            }
        }
        #endif
```

Replace the row (lines 72-77) so editing opens a window on Mac:

```swift
        } content: { feed in
            #if targetEnvironment(macCatalyst)
            Button {
                openWindow(id: WindowID.feedEditor, value: FeedEditorTarget.edit(feed.persistentModelID))
            } label: {
                row(feed)
            }
            .buttonStyle(.plain)
            #else
            NavigationLink {
                FeedEditorView(feed: feed)
            } label: {
                row(feed)
            }
            #endif
        }
```

(Keep `@State private var showingCreateFeed = false` — it is still referenced by the iOS branch.)

- [ ] **Step 5: Remove the now-unused `TimelineModel.createFeed`**

In `Yana/Reader/Mac/TimelineModel.swift`, delete `createFeed(_:)` (lines 219-227) and its `///` doc comment (line 218). Its only caller was the removed `MacRootView` create-feed sheet; the window now runs the fetch itself.

- [ ] **Step 6: Build to verify green (both platforms)**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -3`
Then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: both `** BUILD SUCCEEDED **`. Manual check note: Mac — "Add Feed" (sidebar + empty state + Feeds pane "+") opens a separate editor window; clicking a feed row in the Feeds pane opens an editor window; saving a new enabled feed fetches it and the reader updates. iOS — Feeds add/edit still use the sheet/push.

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/Mac/FeedEditorWindowRoot.swift Yana/YanaApp.swift Yana/Reader/Mac/MacRootView.swift Yana/Views/Config/FeedsView.swift Yana/Reader/Mac/TimelineModel.swift
git commit -m "Present macOS feed editor (create + edit) as separate windows"
```

---

### Task 7: Welcome window

**Files:**
- Create: `Yana/Reader/Mac/WelcomeWindowRoot.swift`
- Modify: `Yana/YanaApp.swift` (add `Window` scene)
- Modify: `Yana/ContentView.swift` (Mac launch opens the welcome window)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (remove `.fullScreenCover(showWelcome)`)
- Modify: `Yana/Reader/Mac/MacSettingsWindow.swift` (About → open welcome window + dismiss)

**Interfaces:**
- Consumes: `WindowID` (Task 1), `WelcomeView` (existing), `AppState`.
- Produces: `struct WelcomeWindowRoot: View` — `init(appState: AppState)`. Owns onboarding completion; self-dismisses if already onboarded (restoration guard).

- [ ] **Step 1: Create `WelcomeWindowRoot.swift`**

```swift
import SwiftUI

/// Hosts the onboarding `WelcomeView` in its own Mac window. Replaces the `.fullScreenCover`'s
/// `onFinish` closure: on finish it sets the completion flag and closes the window. If the window is
/// ever restored after onboarding is already done, it closes itself immediately.
struct WelcomeWindowRoot: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()

    var body: some View {
        WelcomeView(onFinish: {
            settings.hasCompletedOnboarding = true
            appState.showWelcome = false
            dismiss()
        })
        .onAppear {
            if settings.hasCompletedOnboarding { dismiss() }
        }
    }
}
```

- [ ] **Step 2: Add the Welcome scene to `YanaApp.body`**

In `Yana/YanaApp.swift`, alongside the other Mac scenes:

```swift
        Window("Welcome to Yana", id: WindowID.welcome) {
            WelcomeWindowRoot(appState: appState)
                .environment(articleStore)
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 720, height: 640)
```

- [ ] **Step 3: `ContentView` — Mac opens the welcome window on first launch**

In `Yana/ContentView.swift`:
- Add `@Environment(\.openWindow) private var openWindow` (after line 7).
- In the `MacRootView` branch, the `.fullScreenCover` is only in the iOS branch already (line 27-33 is on `ReaderScreen`), so no cover to remove here — but the launch trigger at lines 41-43 must open the window on Mac. Replace the `onAppear` body's final `if` so Mac opens the window instead of setting the flag:

```swift
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_ONBOARDING") {
                settings.hasCompletedOnboarding = false
            }
            if !settings.hasCompletedOnboarding, !Self.skipOnboarding {
                if isMac {
                    openWindow(id: WindowID.welcome)
                } else {
                    appState.showWelcome = true
                }
            }
        }
```

- [ ] **Step 4: `MacRootView` — remove the full-screen welcome cover**

In `Yana/Reader/Mac/MacRootView.swift`, delete the `.fullScreenCover(isPresented: $appState.showWelcome) { … }` block (lines 54-60). The welcome window (Step 2-3) replaces it. `appState.showWelcome` remains the iOS mechanism (untouched in `ReaderScreen`/`ContentView`).

- [ ] **Step 5: `MacSettingsWindow` — About restarts onboarding via the window**

In `Yana/Reader/Mac/MacSettingsWindow.swift`, complete the `.about` case's `onRestartOnboarding` (stubbed in Task 4):

```swift
        case .about:
            Form {
                AboutSettingsSection(onRestartOnboarding: {
                    openWindow(id: WindowID.welcome)
                    dismiss()
                })
            }
```

(`openWindow` and `dismiss` are already declared on `MacSettingsWindow` from Task 4.)

- [ ] **Step 6: Build to verify green**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Manual check note: fresh Mac launch shows the Welcome window; finishing it closes the window and reveals the reader; Settings → About → "Show Welcome Screen Again" reopens the Welcome window and closes Settings; relaunch after onboarding does not re-show Welcome.

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/Mac/WelcomeWindowRoot.swift Yana/YanaApp.swift Yana/ContentView.swift Yana/Reader/Mac/MacRootView.swift Yana/Reader/Mac/MacSettingsWindow.swift
git commit -m "Present macOS onboarding as a separate Welcome window"
```

---

### Task 8: Localization + full verification

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings`
- Modify: `CLAUDE.md` (document the Mac windowing) — optional but recommended per repo convention.

- [ ] **Step 1: Add German translations for new user-facing strings**

New strings introduced by this plan: the pane titles `"General"`, `"Reader"`, `"Feeds"`, `"Tags"`, `"Integrations"`, `"AI"`, `"About"` (several may already exist — only add missing keys), and window titles `"Settings"`, `"Welcome to Yana"`. For each MISSING key, add an entry to `Yana/Resources/Localizable.xcstrings` with a `de` localization marked `"state" : "translated"`, Apple infinitive style. Suggested German:

| Key | de |
|---|---|
| General | Allgemein |
| Reader | Leser |
| Integrations | Integrationen |
| Welcome to Yana | Willkommen bei Yana |

(`Reader`, `Feeds`, `Tags`, `AI`, `About`, `Settings` almost certainly already exist — verify with a search before adding, to avoid duplicates.)

Verify: `grep -c '"General"' Yana/Resources/Localizable.xcstrings` and confirm each new key resolves.

- [ ] **Step 2: Full build (both platforms) + unit tests**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build 2>&1 | tail -3
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -15
```
Expected: build `** BUILD SUCCEEDED **`; tests pass (including `WindowIdentityTests`). If the runner flakes with a Mach `-308` / "server died", shut down simulators and retry — it is not a real failure.

- [ ] **Step 3: Update `CLAUDE.md`**

Under the Mac notes, document that on Mac Catalyst the Welcome, Feed editor, and Settings are separate windows (Settings is a two-pane sidebar of General/Reader/Feeds/Tags/Integrations/AI/About), coordinated via shared state rather than closures, while iOS keeps sheets/cover.

- [ ] **Step 4: Commit**

```bash
git add Yana/Resources/Localizable.xcstrings CLAUDE.md
git commit -m "Localize Mac window/pane titles and document macOS windowing"
```

---

## Self-Review

**Spec coverage:** Welcome window (Task 7) ✓; Feed editor create+edit windows (Task 6) ✓; Settings two-pane window with the seven named panes (Tasks 3-5,7) ✓; General grouping = Notifications+Library+iCloud (Task 4) ✓; iOS unchanged (Tasks 3,6 gate Mac paths) ✓; closures→shared state (Tasks 6,7) ✓; `settingsOpen` cleanup + `.newItem` kept (Task 5) ✓; accessibility ids preserved (Task 3) ✓; nested modals untouched (create-tag/export/feed-search left as-is) ✓; localization (Task 8) ✓.

**Placeholder scan:** The "MOVE lines X-Y verbatim" instructions in Task 3 reference exact existing source with an explicit mechanical transform — these are move operations, not unwritten code. All genuinely new code is shown in full.

**Type consistency:** `FeedEditorTarget`/`WindowID`/`SettingsPane` defined in Task 1 are used with matching names/values throughout. `CredentialTestControls(status:disabled:onClear:action:)` and `CredentialTest.run(_:_:)` defined in Task 2 are consumed identically in Task 3. `openWindow(id:value:)` uses `FeedEditorTarget` values matching the `WindowGroup(for: FeedEditorTarget.self)` scene.
