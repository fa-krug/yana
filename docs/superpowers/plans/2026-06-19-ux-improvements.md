# UX Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address the 17 UX findings from the audit — refresh feedback, error recovery, filter visibility, haptics, settings ergonomics, accessibility, and reader polish — across the SwiftUI views and the UIKit reader.

**Architecture:** Each task is self-contained and independently shippable. Pure logic (refresh-outcome messaging, filter-active state) is extracted into small testable helpers under `Yana/Utilities/`; view-only changes are verified by building for the simulator and a documented manual check. Existing patterns are reused (the `importMessage` toast in `FeedsView`, the `.tintedIcon` label style, `AppSettings` computed properties, `ManagedList`).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, UIKit (reader), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- **Platform:** iOS 26.0+ (iPhone and iPad). Swift 6 strict concurrency — `@MainActor` annotations as in surrounding code.
- **Translations are mandatory.** Every new or changed user-facing string MUST get a `de` entry in `Yana/Resources/Localizable.xcstrings` marked `"state" : "translated"`. German follows Apple style (infinitive for actions, no "Du"/"Sie"). Each task below lists the exact `en`→`de` pairs it introduces.
- **Localization API:** computed `String` values use `String(localized:)`; SwiftUI literal text uses `LocalizedStringKey`.
- **New files require project regeneration:** after creating any new `.swift` file, run `xcodegen generate` before building (the project is globbed from `Yana/` in `project.yml`).
- **Build command (verification):** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- **Test command:** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- **Commit after every task.** Branch is already `claude/nice-nightingale-d19e1a`; do not commit to `main`.

---

### Task 1: Refresh-outcome message helper + new-article feedback in the home reader

Covers audit #1 (refresh completion feedback) and #11 (pull-to-refresh outcome). `FeedsView` already shows a count toast via `importMessage`; the home reader (`ReaderScreen.triggerRefresh`) discards the `updateAll()` count and only surfaces failures. Extract the message logic so both screens share it, then show a transient banner in the reader.

**Files:**
- Create: `Yana/Utilities/RefreshOutcome.swift`
- Create: `YanaTests/RefreshOutcomeTests.swift`
- Modify: `Yana/Views/Config/FeedsView.swift:190-212` (use helper)
- Modify: `Yana/Reader/ReaderHostView.swift:53-153` (`ReaderScreen`: capture count, show banner)
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces: `enum RefreshOutcome { static func message(newCount: Int, feedName: String?) -> String }` — returns "No new articles." for 0; "Added N new article(s)." otherwise; appends ` from "feed"` when `feedName` is non-nil.
- Consumes (Task uses existing): `AggregationService.updateAll() -> Int`, `AggregationService.update(feed:) -> Int`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Yana

@MainActor
struct RefreshOutcomeTests {
    @Test func zeroCountAllFeeds() {
        #expect(RefreshOutcome.message(newCount: 0, feedName: nil) == String(localized: "No new articles."))
    }

    @Test func singularCount() {
        #expect(RefreshOutcome.message(newCount: 1, feedName: nil)
            == String(localized: "Added 1 new article."))
    }

    @Test func pluralCount() {
        #expect(RefreshOutcome.message(newCount: 3, feedName: nil)
            == String(localized: "Added 3 new articles."))
    }

    @Test func namedFeedAppendsSource() {
        let msg = RefreshOutcome.message(newCount: 2, feedName: "Heise")
        #expect(msg.contains("Heise"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RefreshOutcomeTests`
Expected: FAIL — `cannot find 'RefreshOutcome' in scope`.

- [ ] **Step 3: Create the helper**

```swift
import Foundation

/// Builds the user-facing toast after a feed refresh. Shared by the Feeds screen and the
/// home reader so both report new-article counts identically.
enum RefreshOutcome {
    static func message(newCount: Int, feedName: String?) -> String {
        if newCount == 0 {
            if let name = feedName {
                return String(localized: "Reloaded \u{201C}\(name)\u{201D}.")
            }
            return String(localized: "No new articles.")
        }
        let plural = newCount == 1 ? String(localized: "article") : String(localized: "articles")
        if let name = feedName {
            return String(localized: "Added \(newCount) new \(plural) from \u{201C}\(name)\u{201D}.")
        }
        return String(localized: "Added \(newCount) new \(plural).")
    }
}
```

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RefreshOutcomeTests`
Expected: PASS.

- [ ] **Step 5: Route `FeedsView` through the helper**

In `Yana/Views/Config/FeedsView.swift`, replace the bodies of `updateAll()`, `updateOne(_:)`, and `forceReloadOne(_:)` count branches with the helper. Example for `updateAll()` (lines 190-200):

```swift
    private func updateAll() {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).updateAll()
            guard !Task.isCancelled else { return }
            importMessage = RefreshOutcome.message(newCount: count, feedName: nil)
        }
    }
```

And `updateOne(_:)` (lines 202-212):

```swift
    private func updateOne(_ feed: Feed) {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).update(feed: feed)
            guard !Task.isCancelled else { return }
            importMessage = RefreshOutcome.message(newCount: count, feedName: feed.name)
        }
    }
```

And `forceReloadOne(_:)` (lines 214-224):

```swift
    private func forceReloadOne(_ feed: Feed) {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).forceReload(feed: feed)
            guard !Task.isCancelled else { return }
            importMessage = RefreshOutcome.message(newCount: count, feedName: feed.name)
        }
    }
```

- [ ] **Step 6: Show the outcome banner in the home reader**

In `Yana/Reader/ReaderHostView.swift`, add transient state and surface it. Add to `ReaderScreen` after line 61:

```swift
    @State private var statusMessage: String?
```

Replace `triggerRefresh()` (lines 144-152) with:

```swift
    private func triggerRefresh() {
        // A fresh pull cancels any update already running and starts over, rather than no-op'ing.
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.updateAll()
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: nil)
            }
        }
    }
```

Add an overlay banner to the `Group` in `body`. Insert after the `.alert(...)` block (after line 108), before `.onAppear`:

```swift
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.statusMessage = nil
                    }
            }
        }
        .animation(.snappy, value: statusMessage)
```

- [ ] **Step 7: Add translations**

Add to `Yana/Resources/Localizable.xcstrings` (most keys already exist from `FeedsView`; verify and add any missing). Required `en`→`de`:
- `"No new articles."` → `"Keine neuen Artikel."`
- `"Added %lld new %@."` → `"%lld neue %@ hinzugefügt."` (the `Added \(count) new \(plural).` interpolation)
- `"article"` → `"Artikel"`, `"articles"` → `"Artikel"`
- `"Added %lld new %@ from \u{201C}%@\u{201D}."` → `"%lld neue %@ aus \u{201C}%@\u{201D} hinzugefügt."`
- `"Reloaded \u{201C}%@\u{201D}."` → `"\u{201C}%@\u{201D} neu geladen."`

All marked `"state" : "translated"`.

- [ ] **Step 8: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.
Manual: launch app, pull-to-refresh in the reader → a capsule banner shows "No new articles." or "Added N new articles." and auto-dismisses.

- [ ] **Step 9: Commit**

```bash
git add Yana/Utilities/RefreshOutcome.swift YanaTests/RefreshOutcomeTests.swift Yana/Views/Config/FeedsView.swift Yana/Reader/ReaderHostView.swift Yana/Resources/Localizable.xcstrings Yana.xcodeproj
git commit -m "feat(ux): show new-article count after refresh in the reader"
```

---

### Task 2: Retry action on the "Update Failed" alert

Covers audit #2. The home reader's failure alert ([ReaderHostView.swift:101-108](Yana/Reader/ReaderHostView.swift:101)) only offers "OK". Add a "Retry" button that re-runs the refresh.

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift:101-108`

**Interfaces:**
- Consumes: `triggerRefresh()` (existing private method on `ReaderScreen`).

- [ ] **Step 1: Add the Retry button**

Replace the `.alert("Update Failed", ...)` block (lines 101-108) with:

```swift
        .alert("Update Failed", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("Retry") { triggerRefresh() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
```

- [ ] **Step 2: Add translations**

Add to `Localizable.xcstrings`:
- `"Retry"` → `"Erneut versuchen"` (state: translated)

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: trigger a failure (e.g. add a bad feed URL, turn off network), confirm the alert shows "Retry" and tapping it re-runs the update.

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): add Retry to the update-failed alert"
```

---

### Task 3: Filter-active indicator in the reader toolbar

Covers audit #7. The reader's filter button ([ReaderArticleViewController.swift:74-79](Yana/Reader/ReaderArticleViewController.swift:74)) shows the same icon regardless of filter state. `ArticleListView` already flips its icon; the reader can't because it doesn't know the timeline filter state. Add a testable `AppSettings.isTimelineFilterActive` and thread it through the host into the reader.

**Files:**
- Modify: `Yana/Models/AppSettings.swift` (add computed property)
- Create: `YanaTests/TimelineFilterStateTests.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (`ReaderHostView` add binding + pass-through; `ReaderScreen` compute it)
- Modify: `Yana/Reader/ReaderArticleViewController.swift` (apply filled icon)

**Interfaces:**
- Produces: `AppSettings.isTimelineFilterActive: Bool` — `true` when `!disabledTagNames.isEmpty || !includeUntagged`.
- Produces: `ReaderHostView.isFilterActive: Bool` (new stored property) and `ReaderArticleViewController.setFilterActive(_ active: Bool)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Yana

@MainActor
struct TimelineFilterStateTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "filter-state-test")!
        defaults.removePersistentDomain(forName: "filter-state-test")
        return AppSettings(defaults: defaults)
    }

    @Test func inactiveByDefault() {
        #expect(makeSettings().isTimelineFilterActive == false)
    }

    @Test func activeWhenTagDisabled() {
        let s = makeSettings()
        s.disabledTagNames = ["News"]
        #expect(s.isTimelineFilterActive == true)
    }

    @Test func activeWhenUntaggedExcluded() {
        let s = makeSettings()
        s.includeUntagged = false
        #expect(s.isTimelineFilterActive == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineFilterStateTests`
Expected: FAIL — `value of type 'AppSettings' has no member 'isTimelineFilterActive'`.

- [ ] **Step 3: Add the computed property**

In `Yana/Models/AppSettings.swift`, after the `includeUntagged` property (after line 261):

```swift
    /// True when the timeline filter would hide some articles (a tag is off, or untagged
    /// articles are excluded). Drives the reader's filter-button active state.
    var isTimelineFilterActive: Bool {
        !disabledTagNames.isEmpty || !includeUntagged
    }
```

- [ ] **Step 4: Regenerate and run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineFilterStateTests`
Expected: PASS.

- [ ] **Step 5: Add a `setFilterActive` API to the reader**

In `Yana/Reader/ReaderArticleViewController.swift`, add after `setRefreshing` (after line 111):

```swift
    func setFilterActive(_ active: Bool) {
        filterItem.image = UIImage(systemName: active
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle")
    }
```

- [ ] **Step 6: Thread the flag through the host**

In `Yana/Reader/ReaderHostView.swift`, add a stored property to `ReaderHostView` after line 11:

```swift
    let isFilterActive: Bool
```

In `makeUIViewController` after line 26 (`reader.setRefreshing(isRefreshing)`):

```swift
        reader.setFilterActive(isFilterActive)
```

In `updateUIViewController` after line 41 (`reader.setRefreshing(isRefreshing)`):

```swift
        reader.setFilterActive(isFilterActive)
```

In `ReaderScreen.body`, pass it in the `ReaderHostView(...)` initializer (after line 90, alongside `isRefreshing:`):

```swift
                    isFilterActive: settings.isTimelineFilterActive,
```

- [ ] **Step 7: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: open the filter, turn off a tag → the reader's top-left filter icon becomes filled; clear the filter → it returns to outline.

- [ ] **Step 8: Commit**

```bash
git add Yana/Models/AppSettings.swift YanaTests/TimelineFilterStateTests.swift Yana/Reader/ReaderHostView.swift Yana/Reader/ReaderArticleViewController.swift Yana.xcodeproj
git commit -m "feat(ux): reflect active timeline filter in the reader toolbar"
```

---

### Task 4: Tell the user when the saved position can't be restored under the active filter

Covers audit #4. `clampIndex()` ([ReaderHostView.swift:138-140](Yana/Reader/ReaderHostView.swift:138)) silently moves the reader when a filter change invalidates the saved index. Show the same transient banner (added in Task 1) when clamping actually changes the index.

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift:138-140`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `statusMessage` state from Task 1. **Task 1 must land first.**

- [ ] **Step 1: Surface a message on clamp**

Replace `clampIndex()` (lines 138-140) with:

```swift
    private func clampIndex() {
        let clamped = min(appState.currentIndex, max(0, filteredArticles.count - 1))
        if clamped != appState.currentIndex {
            statusMessage = String(localized: "Showing the nearest article in this filter.")
        }
        appState.currentIndex = clamped
    }
```

- [ ] **Step 2: Add translations**

Add to `Localizable.xcstrings`:
- `"Showing the nearest article in this filter."` → `"Nächstgelegener Artikel in diesem Filter wird angezeigt."` (state: translated)

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: scroll deep into the timeline, open the filter and disable most tags so the current index is out of range → on dismiss a banner explains the jump.

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): explain reader position jumps after filter changes"
```

---

### Task 5: Haptic feedback on key actions

Covers audit #15. Add a thin haptics helper and fire it on star/unstar, delete confirmation, and refresh trigger.

**Files:**
- Create: `Yana/Utilities/Haptics.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (`toggleStar`, `triggerRefresh`)
- Modify: `Yana/Views/Config/ArticleListView.swift` (star action, delete)
- Modify: `Yana/Views/Config/FeedsView.swift` (delete)
- Modify: `Yana/Views/Config/TagsView.swift` (delete)

**Interfaces:**
- Produces: `enum Haptics { static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle); static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) }`.

- [ ] **Step 1: Create the helper**

```swift
import UIKit

/// Centralized, light wrapper around UIKit feedback generators so action sites stay terse.
@MainActor
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
```

- [ ] **Step 2: Regenerate the project**

Run: `xcodegen generate`
Expected: succeeds (new file picked up).

- [ ] **Step 3: Wire into the reader**

In `Yana/Reader/ReaderHostView.swift`, in `toggleStar(_:)` (line 116-120) add after `article.setStarred(...)`:

```swift
        Haptics.impact(.light)
```

In `triggerRefresh()`, on the success path (after computing `statusMessage` from Task 1) add:

```swift
                Haptics.impact(.light)
```

- [ ] **Step 4: Wire into the config lists**

In `Yana/Views/Config/ArticleListView.swift`, in the star `leadingActions` button (after line 50 `try? modelContext.save()`):

```swift
                    Haptics.impact(.light)
```

In the delete confirmation `Delete` button (after line 104 `try? modelContext.save()`):

```swift
                    Haptics.notify(.success)
```

In `Yana/Views/Config/FeedsView.swift`, in the delete `Delete` button (after line 122 `try? modelContext.save()`):

```swift
                    Haptics.notify(.success)
```

In `Yana/Views/Config/TagsView.swift`, in the delete `Delete` button (after line 70 `delete(resolved)`):

```swift
                Haptics.notify(.success)
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual (on a device if available — the simulator does not vibrate): star an article, delete a feed → feel the feedback. No new strings, so no translation step.

- [ ] **Step 6: Commit**

```bash
git add Yana/Utilities/Haptics.swift Yana/Reader/ReaderHostView.swift Yana/Views/Config/ArticleListView.swift Yana/Views/Config/FeedsView.swift Yana/Views/Config/TagsView.swift Yana.xcodeproj
git commit -m "feat(ux): add haptic feedback to star, refresh, and delete"
```

---

### Task 6: Collapse advanced AI tuning behind disclosure

Covers audit #8. The `aiKnobsSection` ([SettingsScreenView.swift:305-322](Yana/Views/Config/SettingsScreenView.swift:305)) dumps nine advanced steppers inline. Wrap the rarely-touched knobs in a `DisclosureGroup` so the section defaults to collapsed.

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift:305-322`
- Modify: `Yana/Resources/Localizable.xcstrings`

- [ ] **Step 1: Wrap the knobs in a disclosure group**

Replace `aiKnobsSection` (lines 305-322) with:

```swift
    private var aiKnobsSection: some View {
        Section("AI Tuning") {
            HStack {
                Text("Temperature")
                Slider(value: $settings.aiTemperature, in: 0...1, step: 0.05)
                Text(settings.aiTemperature, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Stepper("Max Tokens: \(settings.aiMaxTokens)", value: $settings.aiMaxTokens, in: 256...8000, step: 256)
            DisclosureGroup("Advanced") {
                Stepper("Max Prompt Length: \(settings.aiMaxPromptLength)", value: $settings.aiMaxPromptLength, in: 100...4000, step: 100)
                Stepper("Daily Limit: \(settings.aiDefaultDailyLimit)", value: $settings.aiDefaultDailyLimit, in: 0...5000, step: 50)
                Stepper("Monthly Limit: \(settings.aiDefaultMonthlyLimit)", value: $settings.aiDefaultMonthlyLimit, in: 0...50000, step: 100)
                Stepper("Request Timeout: \(settings.aiRequestTimeout)s", value: $settings.aiRequestTimeout, in: 10...600, step: 10)
                Stepper("Max Retries: \(settings.aiMaxRetries)", value: $settings.aiMaxRetries, in: 0...10)
                Stepper("Retry Delay: \(settings.aiRetryDelay)s", value: $settings.aiRetryDelay, in: 0...60)
                Stepper("Request Delay: \(settings.aiRequestDelay)s", value: $settings.aiRequestDelay, in: 0...60)
            }
        }
    }
```

- [ ] **Step 2: Add translations**

Add to `Localizable.xcstrings`:
- `"Advanced"` → `"Erweitert"` (state: translated)

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: open Settings → AI Tuning shows Temperature + Max Tokens with an "Advanced" disclosure hiding the rest until expanded.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): collapse advanced AI tuning knobs behind a disclosure"
```

---

### Task 7: Credential-test UX — lock inputs during a test, allow dismissing a failure

Covers audit #9. While `status == .testing`, the secret fields stay editable; an `.invalid` status lingers until the user edits the credential. Disable the relevant fields during a test and add a "Clear" button to dismiss a failure.

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (`testControls`, and pass an `onClear`)

**Interfaces:**
- Modifies: `testControls(status:disabled:action:)` → `testControls(status:disabled:onClear:action:)`. All call sites add `onClear: { <statusSetter> = .idle }`.

- [ ] **Step 1: Extend `testControls` with a clear affordance**

Replace `testControls` (lines 338-364) with:

```swift
    /// A "Test" button plus an inline status row, reused by every credential section.
    @ViewBuilder
    private func testControls(status: TestStatus, disabled: Bool,
                             onClear: @escaping () -> Void,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("Test")
                if status == .testing {
                    Spacer()
                    Text("Testing…")
                        .foregroundStyle(.secondary)
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
                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)
            }
        }
    }
```

- [ ] **Step 2: Update every call site to pass `onClear`**

Each `testControls(...)` call gains an `onClear:` that resets its own status. There are eight: reddit, youtube, openai, anthropic, gemini, mistral, qwen, deepseek, and apple. Example (reddit, line 117):

```swift
            testControls(status: redditStatus,
                         disabled: redditClientID.isEmpty || redditClientSecret.isEmpty,
                         onClear: { redditStatus = .idle }) {
                runTest({ redditStatus = $0 }) {
                    await CredentialTester.reddit(clientID: redditClientID,
                                                  clientSecret: redditClientSecret,
                                                  userAgent: settings.redditUserAgent)
                }
            }
```

Apply the same `onClear: { <providerStatus> = .idle }` to youtube (`youtubeStatus`), openai (`openaiStatus`), anthropic (`anthropicStatus`), gemini (`geminiStatus`), mistral (`mistralStatus`), qwen (`qwenStatus`), deepseek (`deepseekStatus`), and apple (`appleStatus`).

- [ ] **Step 3: Disable secret fields while testing**

For each provider's `SecureField`/`TextField`, add `.disabled(<providerStatus> == .testing)`. Example for reddit (lines 107-115):

```swift
            SecureField("Client ID", text: $redditClientID)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientID) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientID); redditStatus = .idle
                }
            SecureField("Client Secret", text: $redditClientSecret)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientSecret) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientSecret); redditStatus = .idle
                }
```

Apply `.disabled(<providerStatus> == .testing)` to the YouTube key field and each AI provider's `SecureField` (and OpenAI's API URL `TextField`).

- [ ] **Step 4: Add translations**

Add to `Localizable.xcstrings`:
- `"Clear"` → `"Löschen"` (state: translated)

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: enter a bad key, tap Test → fields lock during the probe, an error row with a "Clear" button appears; tapping Clear resets the status.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): lock credential fields during test and allow clearing failures"
```

---

### Task 8: Live text-size preview in the Reader settings section

Covers audit #6. The text-size picker ([SettingsScreenView.swift:77-87](Yana/Views/Config/SettingsScreenView.swift:77)) gives no sense of the resulting size. Add a sample-text row that scales with the selected `ArticleTextSize.pointSize`.

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (`readerSection`)
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ArticleTextSize.pointSize` (existing, [ArticleTextSize.swift:27](Yana/Reader/ArticleTextSize.swift:27)).

- [ ] **Step 1: Add a preview row under the picker**

In `readerSection`, after the Text Size `Picker` closing (after line 87, before the `Toggle`), insert:

```swift
            Text("The quick brown fox jumps over the lazy dog.")
                .font(.system(size: CGFloat(settings.articleTextSize.pointSize)))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Text size preview"))
```

- [ ] **Step 2: Add translations**

Add to `Localizable.xcstrings`:
- `"The quick brown fox jumps over the lazy dog."` → `"Franz jagt im komplett verwahrlosten Taxi quer durch Bayern."` (German pangram; state: translated)
- `"Text size preview"` → `"Vorschau der Textgröße"` (state: translated)

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: open Settings → Reader, change Text Size → the sample sentence resizes immediately.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): live text-size preview in reader settings"
```

---

### Task 9: Strengthen article/feed row visual hierarchy

Covers audit #10. In `ArticleListView.row` the feed name and date share the same `.caption` weight; emphasize the feed name and keep the date quiet. Keep changes minimal and consistent with `FeedsView`.

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift:115-131`

- [ ] **Step 1: Adjust the row metadata styling**

Replace `row(_:)` (lines 115-131) with:

```swift
    private func row(_ article: Article) -> some View {
        HStack(spacing: 12) {
            FeedLogoView(hash: article.feed?.logoHash)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let name = article.feed?.name, !name.isEmpty {
                        Text(name)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(article.date, style: .date)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: open the Articles list → the feed name reads as the stronger secondary element and the date recedes. No new strings.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift
git commit -m "refactor(ux): clearer article row metadata hierarchy"
```

---

### Task 10: Clarify the locked built-in (Starred) tag

Covers audit #12. The `lock.fill` glyph ([TagsView.swift:42-44](Yana/Views/Config/TagsView.swift:42)) and the disabled name field ([TagEditorView.swift:29-30](Yana/Views/Config/TagEditorView.swift:29)) are unexplained. Add an accessibility label to the lock and an explanatory footer in the editor.

**Files:**
- Modify: `Yana/Views/Config/TagsView.swift:42-44`
- Modify: `Yana/Views/Config/TagEditorView.swift:28-32`
- Modify: `Yana/Resources/Localizable.xcstrings`

- [ ] **Step 1: Label the lock glyph**

In `TagsView.swift`, replace lines 42-44:

```swift
                    if tag.isBuiltIn {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("System tag"))
                    }
```

- [ ] **Step 2: Explain the disabled name field**

In `TagEditorView.swift`, replace the `Form` body's name field (lines 28-32) with a section that carries a footer when the tag is built-in:

```swift
        Form {
            Section {
                TextField("Name", text: $name)
                    .disabled(tag?.isBuiltIn == true)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            } footer: {
                if tag?.isBuiltIn == true {
                    Text("This is a system tag. You can recolor it, but its name is fixed.")
                }
            }
        }
```

- [ ] **Step 3: Add translations**

Add to `Localizable.xcstrings`:
- `"System tag"` → `"Systemstichwort"` (state: translated)
- `"This is a system tag. You can recolor it, but its name is fixed."` → `"Dies ist ein Systemstichwort. Die Farbe lässt sich ändern, der Name ist fest."` (state: translated)

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: open the Starred tag editor → the footer explains why the name is locked.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/TagsView.swift Yana/Views/Config/TagEditorView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): explain the locked system (Starred) tag"
```

---

### Task 11: Keyboard handling on credential and name fields

Covers audit #13. Secret fields in Settings lack `.autocorrectionDisabled()` / `.textInputAutocapitalization(.never)`, so iOS may mangle pasted keys; the feed/tag name fields lack `.submitLabel`. Apply the input traits.

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (all `SecureField`s + OpenAI API URL `TextField`)
- Modify: `Yana/Views/Config/FeedEditorView.swift:30` (name field submit label)
- Modify: `Yana/Views/Config/TagEditorView.swift` (name field submit label)

- [ ] **Step 1: Harden the secret fields**

For every `SecureField` in `SettingsScreenView.swift` (reddit client id/secret, youtube key, and each AI provider key) and the OpenAI API-URL `TextField`, append:

```swift
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
```

Place these modifiers immediately after each field declaration (before its `.onChange`/`.disabled`). Example (reddit Client ID):

```swift
            SecureField("Client ID", text: $redditClientID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientID) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientID); redditStatus = .idle
                }
```

- [ ] **Step 2: Add submit labels to name fields**

In `FeedEditorView.swift` line 30:

```swift
                TextField("Name", text: $model.name)
                    .submitLabel(.done)
```

In `TagEditorView.swift`, the name `TextField` (inside the Section from Task 10):

```swift
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .disabled(tag?.isBuiltIn == true)
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: paste an API key with mixed case → no autocapitalization/autocorrect; the keyboard return key reads "Done" on name fields. No new strings.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Views/Config/FeedEditorView.swift Yana/Views/Config/TagEditorView.swift
git commit -m "fix(ux): correct keyboard traits on credential and name fields"
```

---

### Task 12: Dynamic Type robustness on stepper labels

Covers audit #14. The `Stepper` labels in Settings ([SettingsScreenView.swift:313-320](Yana/Views/Config/SettingsScreenView.swift:313)) can crowd or clip at large accessibility sizes. Allow the labels to wrap rather than truncate.

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (`aiKnobsSection` steppers + `librarySection`)

- [ ] **Step 1: Let stepper labels wrap**

For the plain-string `Stepper(...)` calls in `aiKnobsSection` (the Max Tokens stepper and each stepper inside the "Advanced" disclosure from Task 6), add `.lineLimit(2)` and `.minimumScaleFactor(0.8)`. Example:

```swift
            Stepper("Max Tokens: \(settings.aiMaxTokens)", value: $settings.aiMaxTokens, in: 256...8000, step: 256)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
```

Apply the same two modifiers to: Max Prompt Length, Daily Limit, Monthly Limit, Request Timeout, Max Retries, Retry Delay, Request Delay.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: Settings app → Accessibility → Larger Text at a large size, open Yana Settings → AI Tuning labels wrap/scale instead of clipping. No new strings.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift
git commit -m "fix(ux): keep stepper labels legible at large Dynamic Type sizes"
```

---

### Task 13: First-run hint for reader full-screen mode

Covers audit #16. Tapping the nav-bar title toggles full-screen ([ReaderArticleViewController.swift:54-62](Yana/Reader/ReaderArticleViewController.swift:54)) but the gesture is undiscoverable. Show a one-time hint banner the first time the reader appears.

**Files:**
- Modify: `Yana/Models/AppSettings.swift` (add `hasSeenFullscreenHint` flag)
- Modify: `Yana/Reader/ReaderHostView.swift` (`ReaderScreen`: show the hint once via `statusMessage`)
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces: `AppSettings.hasSeenFullscreenHint: Bool` (UserDefaults-backed, default false).
- Consumes: `statusMessage` from Task 1. **Task 1 must land first.**

- [ ] **Step 1: Add the persisted flag**

In `AppSettings.swift`, add a key to the `Key` enum (after line 131):

```swift
        static let hasSeenFullscreenHint = "settings.hasSeenFullscreenHint"
```

And a property (after `articleFullscreenEnabled`, line 283):

```swift
    var hasSeenFullscreenHint: Bool {
        get { access(keyPath: \.hasSeenFullscreenHint); return defaults.bool(forKey: Key.hasSeenFullscreenHint) }
        set { withMutation(keyPath: \.hasSeenFullscreenHint) { defaults.set(newValue, forKey: Key.hasSeenFullscreenHint) } }
    }
```

- [ ] **Step 2: Show the hint once**

In `ReaderScreen.body`, change `.onAppear { restoreAnchor() }` (line 109) to also show the hint:

```swift
        .onAppear {
            restoreAnchor()
            if !settings.hasSeenFullscreenHint, UIDevice.current.userInterfaceIdiom == .phone {
                statusMessage = String(localized: "Tap the title bar to hide the toolbars.")
                settings.hasSeenFullscreenHint = true
            }
        }
```

Add `import UIKit` to the top of `ReaderHostView.swift` if not already present (it is — line 3).

- [ ] **Step 3: Add translations**

Add to `Localizable.xcstrings`:
- `"Tap the title bar to hide the toolbars."` → `"Auf die Titelleiste tippen, um die Symbolleisten auszublenden."` (state: translated)

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: fresh install (reset the simulator's app data) → first reader open shows the hint once; subsequent launches do not.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Reader/ReaderHostView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): one-time hint for reader full-screen gesture"
```

---

### Task 14: Present the share sheet from the top-most controller in the reader

Covers audit #17. `shareArticle()` ([ReaderArticleViewController.swift:176-181](Yana/Reader/ReaderArticleViewController.swift:176)) presents from `self`, which is a page inside a `UIPageViewController` and can fail silently — especially in full-screen mode. Reuse the same top-most-presenter approach already proven in `ReaderWebViewController`.

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift:176-181`

- [ ] **Step 1: Add a top-most-presenter helper and use it**

Replace `shareArticle()` (lines 176-181) with:

```swift
    @objc private func shareArticle() {
        guard let article = currentArticle(), let url = URL(string: article.url) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let presenter = topmostPresenter ?? self
        activity.popoverPresentationController?.barButtonItem = shareItem
        presenter.present(activity, animated: true)
    }

    /// The deepest currently-presented controller reachable from this scene's root, or nil if
    /// the view is not yet in a window. Mirrors ReaderWebViewController.topmostPresenter.
    private var topmostPresenter: UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: tap Share in the reader (normal mode) → share sheet appears anchored to the toolbar button. No new strings.

- [ ] **Step 3: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift
git commit -m "fix(ux): present reader share sheet from top-most controller"
```

---

### Task 15: More actionable empty states + consistent destructive copy

Covers audit #3 (empty-state guidance) and #5 (destructive wording). `ArticleListView`'s empty copy is a dead end ("Add feeds and refresh…" with no path). Extend `ManagedList` with an optional empty-state action button, then give the Articles screen a button that jumps to the Feeds tab. Also align the feed-delete copy so the permanence is explicit.

**Files:**
- Modify: `Yana/Views/Config/ManagedList.swift` (add optional `emptyAction`)
- Modify: `Yana/Views/Config/ConfigHubView.swift` (read to confirm tab-switch mechanism)
- Modify: `Yana/Views/Config/ArticleListView.swift` (pass an empty action; copy)
- Modify: `Yana/Views/Config/FeedsView.swift:127-131` (delete copy)
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces: `ManagedList` gains `var emptyActionTitle: LocalizedStringKey? = nil` and `var emptyAction: (() -> Void)? = nil`; when both are set the non-search empty state renders a bordered-prominent button.

- [ ] **Step 1: Inspect `ConfigHubView` to learn how tabs/navigation are structured**

Read `Yana/Views/Config/ConfigHubView.swift`. Determine whether the Articles and Feeds screens are tabs or navigation destinations, so the empty-state button can route correctly. If routing requires shared selection state not present, fall back to clearer copy only (skip the button) and note it. Record the chosen mechanism before Step 2.

- [ ] **Step 2: Add an optional empty-state action to `ManagedList`**

In `Yana/Views/Config/ManagedList.swift`, add two stored properties after line 22:

```swift
    var emptyActionTitle: LocalizedStringKey? = nil
    var emptyAction: (() -> Void)? = nil
```

Replace the `.overlay` empty branch (lines 43-52) with:

```swift
        .overlay {
            if items.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptyIcon)
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        if let emptyActionTitle, let emptyAction {
                            Button(emptyActionTitle, action: emptyAction)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
```

Also add the two new parameters (with `nil` defaults) to the `Leading == EmptyView` convenience initializer (after line 65) and assign them in its body, so existing call sites compile unchanged:

```swift
        emptyActionTitle: LocalizedStringKey? = nil,
        emptyAction: (() -> Void)? = nil,
```
```swift
        self.emptyActionTitle = emptyActionTitle
        self.emptyAction = emptyAction
```

- [ ] **Step 3: Wire the Articles empty state**

In `ArticleListView.swift`, if Step 1 found a usable routing mechanism, pass `emptyActionTitle:`/`emptyAction:` into the `ManagedList(...)` call and update the copy. If routing is not available, only update the copy. Use:
- `emptyDescription:` → `"No articles yet. Add feeds, then pull to refresh."`
- `emptyActionTitle:` (only if routable) → `"Go to Feeds"` with `emptyAction:` performing the navigation found in Step 1.

- [ ] **Step 4: Make feed-delete permanence explicit**

In `FeedsView.swift`, replace the delete message (lines 127-131):

```swift
            if let feed = feedToDelete {
                Text(
                    String(localized: "Delete \u{201C}\(feed.name)\u{201D}? Its \(feed.articles.count) articles will be permanently deleted.")
                )
            }
```

- [ ] **Step 5: Add translations**

Add to `Localizable.xcstrings`:
- `"No articles yet. Add feeds, then pull to refresh."` → `"Noch keine Artikel. Feeds hinzufügen und dann zum Aktualisieren ziehen."` (state: translated)
- `"Go to Feeds"` → `"Zu den Feeds"` (state: translated, only if used)
- `"Delete \u{201C}%@\u{201D}? Its %lld articles will be permanently deleted."` → `"\u{201C}%@\u{201D} löschen? Die %lld Artikel werden endgültig gelöscht."` (state: translated)

- [ ] **Step 6: Build and verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Manual: with no feeds, open Articles → empty state reads clearly (and offers a "Go to Feeds" button if routing was wired); delete a feed → message states deletion is permanent.

- [ ] **Step 7: Commit**

```bash
git add Yana/Views/Config/ManagedList.swift Yana/Views/Config/ArticleListView.swift Yana/Views/Config/FeedsView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(ux): actionable empty states and explicit destructive copy"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests pass, including `RefreshOutcomeTests` and `TimelineFilterStateTests`.

- [ ] **Confirm translation completeness**

Verify every new key in `Yana/Resources/Localizable.xcstrings` has a `de` entry marked `"state" : "translated"`. No English-only new strings.

- [ ] **Update project docs if needed**

Per `CLAUDE.md`, review whether the architecture summary needs a note (e.g., the new `RefreshOutcome`/`Haptics` utilities). Use the `updating-project-docs` skill before the final merge.
