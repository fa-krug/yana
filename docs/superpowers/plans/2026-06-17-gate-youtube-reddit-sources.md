# Gate YouTube / Reddit on Enabled Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the inert `AppSettings.redditEnabled` / `youtubeEnabled` toggles actually gate those sources — skip their feeds in aggregation, mark them in the Feeds list, disable their swipe-update actions, and hide them from the feed-creation type picker.

**Architecture:** A single helper `AppSettings.isSourceEnabled(_:)` is the source of truth. `AggregationService` (settings injected via init) skips inactive-source feeds; `FeedEditorView` filters the type picker; `FeedsView` shows a badge and disables swipe actions.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`). Build/test via `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`.

## Global Constraints

- **Swift 6 strict concurrency**; views and `AppSettings`/`AggregationService` are `@MainActor`.
- **Platform:** iOS 26.0+.
- **Translations REQUIRED:** every new user-facing string must be added to `Yana/Resources/Localizable.xcstrings` with an `en` source and a `de` translation marked `"state": "translated"`. German uses Apple style (infinitive for actions, no "Du"/"Sie").
- **"Not active" = the per-source Enabled toggle is off** (`redditEnabled` / `youtubeEnabled`). API-key presence is NOT part of this gate.
- Sources are off by default (toggles are not in registered defaults → `false`).
- Do NOT write `feed.lastError` when skipping a feed for an inactive source — a disabled source is not a failure.

---

### Task 1: `AppSettings.isSourceEnabled(_:)`

**Files:**
- Modify: `Yana/Models/AppSettings.swift` (add method in the `// MARK: Sources` area, after `youtubeEnabled`, around line 129)
- Test: `YanaTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `func isSourceEnabled(_ type: AggregatorType) -> Bool` on `AppSettings` (`@MainActor`). Returns `redditEnabled` for `.reddit`, `youtubeEnabled` for `.youtube`, `true` otherwise.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/AppSettingsTests.swift` inside the `AppSettings` suite:

```swift
@Test func isSourceEnabledGatesRedditAndYouTube() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)

    // Off by default.
    #expect(settings.isSourceEnabled(.reddit) == false)
    #expect(settings.isSourceEnabled(.youtube) == false)
    // Non-gated types are always active.
    #expect(settings.isSourceEnabled(.feedContent) == true)
    #expect(settings.isSourceEnabled(.heise) == true)

    settings.redditEnabled = true
    settings.youtubeEnabled = true
    #expect(settings.isSourceEnabled(.reddit) == true)
    #expect(settings.isSourceEnabled(.youtube) == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettings`
Expected: FAIL — `value of type 'AppSettings' has no member 'isSourceEnabled'` (compile error).

- [ ] **Step 3: Write minimal implementation**

In `Yana/Models/AppSettings.swift`, after the `youtubeEnabled` computed property (around line 129), add:

```swift
/// Whether the given aggregator type's content source is currently active.
/// Reddit / YouTube are gated by their per-source Enabled toggle; every other
/// type is always active.
func isSourceEnabled(_ type: AggregatorType) -> Bool {
    switch type {
    case .reddit: return redditEnabled
    case .youtube: return youtubeEnabled
    default: return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettings`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift YanaTests/AppSettingsTests.swift
git commit -m "feat(settings): add isSourceEnabled gate for Reddit/YouTube"
```

---

### Task 2: `AggregationService` skips inactive sources

**Files:**
- Modify: `Yana/Services/AggregationService.swift` (init around lines 42-54; `updateAll()` around lines 134-139; `update(feed:)` around lines 172-179; `forceReload(feed:)` around lines 185-192)
- Test: `YanaTests/AggregationServiceTests.swift`

**Interfaces:**
- Consumes: `AppSettings.isSourceEnabled(_:)` from Task 1.
- Produces: `AggregationService.init` gains `settings: AppSettings = AppSettings()` as the LAST parameter; stored as `private let settings: AppSettings`. `updateAll()` only aggregates feeds where `settings.isSourceEnabled(feed.type)`. `update(feed:)` and `forceReload(feed:)` return `0` without mutating the feed when `!settings.isSourceEnabled(feed.type)`.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/AggregationServiceTests.swift`. Note `freshDefaults()` is not yet in this file — add the helper too:

```swift
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "AggregationServiceTests.\(UUID().uuidString)")!
}

@Test func updateAllSkipsFeedsOfDisabledSource() async throws {
    let context = try makeContext()
    let rss = Feed(name: "rss", aggregatorType: .feedContent, identifier: "a")
    let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
    context.insert(rss); context.insert(reddit)

    // Reddit toggle off (default) -> reddit feed skipped.
    let settings = AppSettings(defaults: freshDefaults())
    let service = AggregationService(
        context: context,
        makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
        settings: settings
    )
    await service.updateAll()

    #expect(rss.articles.count == 1)
    #expect(reddit.articles.isEmpty)
    #expect(reddit.lastError == nil)
}

@Test func updateFeedSkipsDisabledSourceWithoutError() async throws {
    let context = try makeContext()
    let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
    context.insert(reddit)

    let settings = AppSettings(defaults: freshDefaults()) // reddit off
    let service = AggregationService(
        context: context,
        makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
        settings: settings
    )
    let inserted = await service.update(feed: reddit)

    #expect(inserted == 0)
    #expect(reddit.articles.isEmpty)
    #expect(reddit.lastError == nil)
    #expect(reddit.lastFetchedAt == nil)
}

@Test func updateFeedRunsWhenSourceEnabled() async throws {
    let context = try makeContext()
    let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
    context.insert(reddit)

    let settings = AppSettings(defaults: freshDefaults())
    settings.redditEnabled = true
    let service = AggregationService(
        context: context,
        makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
        settings: settings
    )
    let inserted = await service.update(feed: reddit)

    #expect(inserted == 1)
    #expect(reddit.articles.count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationService`
Expected: FAIL — `AggregationService.init` has no `settings:` parameter (compile error).

- [ ] **Step 3: Add the injectable setting and store it**

In `Yana/Services/AggregationService.swift`, add a stored property next to the other `private let`s (after line 40):

```swift
    private let settings: AppSettings
```

Update `init` (lines 42-54) to add `settings` as the last parameter and assign it:

```swift
    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now },
        logoResolver: @escaping LogoResolver = AggregationService.defaultLogoResolver,
        settings: AppSettings = AppSettings()
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.injectedAIProcessor = aiProcessor
        self.now = now
        self.logoResolver = logoResolver
        self.settings = settings
    }
```

- [ ] **Step 4: Filter `updateAll()` by source**

In `updateAll()`, replace the fetch (lines 138-139):

```swift
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = (try? context.fetch(descriptor)) ?? []
```

with (the `#Predicate` can't read the toggle, so filter in Swift after the fetch):

```swift
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = ((try? context.fetch(descriptor)) ?? [])
            .filter { settings.isSourceEnabled($0.type) }
```

- [ ] **Step 5: Guard `update(feed:)` and `forceReload(feed:)`**

In `update(feed:)`, add as the first line of the body (before `lastRunFailures = []`, line 173):

```swift
        guard settings.isSourceEnabled(feed.type) else { return 0 }
```

In `forceReload(feed:)`, add as the first line of the body (before `lastRunFailures = []`, line 186):

```swift
        guard settings.isSourceEnabled(feed.type) else { return 0 }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationService`
Expected: PASS (new tests pass; existing `updateAllImportsArticlesFromEnabledFeedsOnly` etc. still pass — they use `.feedContent`, always active).

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat(aggregation): skip feeds whose source toggle is off"
```

---

### Task 3: Hide inactive source types from the feed-creation picker

**Files:**
- Modify: `Yana/Views/Config/FeedEditorView.swift` (add `settings` state ~line 12; change the type `Picker`'s `ForEach`, lines 23-27)

**Interfaces:**
- Consumes: `AppSettings.isSourceEnabled(_:)` from Task 1; `model.type` (current `AggregatorType`).
- Produces: type picker lists `AggregatorType.allCases` filtered to source-enabled types unioned with the feed's current type.

This is a SwiftUI view change with no unit test (the project has no view tests for editors; `FeedEditorModelTests` covers the model, which is unchanged). Verify by build + manual check.

- [ ] **Step 1: Add settings state**

In `FeedEditorView`, after `@State private var showingSearch = false` (line 12), add:

```swift
    @State private var settings = AppSettings()
```

- [ ] **Step 2: Filter the type picker**

Replace the type `Picker` block (lines 23-27):

```swift
                Picker("Type", selection: Binding(get: { model.type }, set: { model.changeType($0) })) {
                    ForEach(AggregatorType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
```

with:

```swift
                Picker("Type", selection: Binding(get: { model.type }, set: { model.changeType($0) })) {
                    ForEach(availableTypes) { type in
                        Text(type.displayName).tag(type)
                    }
                }
```

Then add a computed property to the view (e.g. just above `var body`):

```swift
    /// Source-enabled types, always including the feed's current type so an existing
    /// feed of a now-inactive source still shows a valid selection while editing.
    private var availableTypes: [AggregatorType] {
        AggregatorType.allCases.filter { settings.isSourceEnabled($0) || $0 == model.type }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/FeedEditorView.swift
git commit -m "feat(feeds): hide disabled-source types from the new-feed picker"
```

---

### Task 4: Feeds list badge + disabled swipe actions

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift` (add `settings` state ~line 16; swipe `.disabled(...)` lines 42 and 49; `row(_:)` badge, around lines 124-127)
- Modify: `Yana/Resources/Localizable.xcstrings` (new badge strings)

**Interfaces:**
- Consumes: `AppSettings.isSourceEnabled(_:)` from Task 1.
- Produces: per-feed badge text "%@ off" (source display name) when the source is inactive; swipe Update / Force reload buttons disabled for inactive-source feeds.

SwiftUI view change; verify by build + manual check.

- [ ] **Step 1: Add settings state**

In `FeedsView`, after `@State private var searchText = ""` (line 16), add:

```swift
    @State private var settings = AppSettings()
```

- [ ] **Step 2: Disable swipe actions for inactive sources**

Change the "Update" button's modifier (line 42) from:

```swift
                .disabled(isUpdating)
```

to:

```swift
                .disabled(isUpdating || !settings.isSourceEnabled(feed.type))
```

Change the "Force reload" button's modifier (line 49) the same way:

```swift
                .disabled(isUpdating || !settings.isSourceEnabled(feed.type))
```

- [ ] **Step 3: Add the badge to the row**

In `row(_:)`, the title `HStack` (lines 123-133) currently shows the name, an optional "Disabled" label, and an optional error icon. Add the source-off badge after the "Disabled" label block (after line 127):

```swift
                if !settings.isSourceEnabled(feed.type) {
                    Text("\(feed.type.displayName) off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 4: Add localized strings**

Add the new key to `Yana/Resources/Localizable.xcstrings`. The string interpolates the source name, so the key is `%@ off`. Add an entry with `en` source value `%@ off` and a `de` translation `%@ aus`, both `"state": "translated"`. Match the existing JSON structure (a `localizations` object keyed by language, each with `stringUnit` → `state` + `value`). Example entry to insert under `"strings"`:

```json
"%@ off" : {
  "localizations" : {
    "de" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "%@ aus"
      }
    }
  }
}
```

(The `en` source value equals the key, which is the catalog convention — no separate `en` entry is required, but if the file lists `en` explicitly for other keys, add a matching `en` localization with value `%@ off`.)

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(feeds): badge and disabled swipe actions for off sources"
```

---

### Task 5: Full test + build verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: TEST SUCCEEDED. If any pre-existing test fails because it aggregated a Reddit/YouTube feed without enabling the source, fix that test to enable the source via injected `AppSettings` (Task 2 pattern) — do not weaken the gate.

- [ ] **Step 2: Confirm strings are translated**

Confirm the new `%@ off` key in `Yana/Resources/Localizable.xcstrings` has a `de` value marked `"state": "translated"`.

- [ ] **Step 3: Commit any fixups**

```bash
git add -A
git commit -m "test: verify YouTube/Reddit source gating"
```

(Skip if nothing changed.)
```

## Self-Review

- **Spec coverage:** §1 helper → Task 1. §2 aggregation skip (all three methods, no lastError) → Task 2. §3 picker union-with-current-type → Task 3. §4 badge → Task 4. §5 swipe disable → Task 4. Strings → Task 4 + Task 5. Tests → Tasks 1, 2, 5. All covered.
- **Placeholders:** none — all code/commands shown.
- **Type consistency:** `isSourceEnabled(_ type: AggregatorType) -> Bool` used identically across Tasks 1-4; `AggregationService.init(... settings:)` defined in Task 2 and consumed in its own tests; `availableTypes`/badge are view-local. Consistent.
