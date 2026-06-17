# Sync Failure Surfacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make feed sync failures visible and understandable — in the reader (where users sync) and the Feeds list — and replace unhelpful generic error text with a clear message.

**Architecture:** `AggregationService` records per-run failures (`lastRunFailures`) and maps errors to user-facing strings via a pure helper. The reader reads those failures after `updateAll()` and shows an alert built by a pure `SyncFailureSummary` helper, finally using the dead `AppState.errorMessage`. The Feeds list error text gets uncapped.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / Swift Testing (`import Testing`). Project is generated with XcodeGen.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` throughout. `AggregatorFactory` is `@Sendable` — do not capture mutable `var`s in test factories; use a small `@unchecked Sendable` holder class.
- Platform: iOS 26.0+.
- New test files require `xcodegen generate` before they compile into the project.
- ALWAYS add German (`de`) translations, state `"translated"`, for every new user-facing string in `Yana/Resources/Localizable.xcstrings`. German: Apple style, infinitive for actions, no "Du"/"Sie".
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/<Suite> test`
- `updateAll()` and `update(feed:)` MUST keep returning `Int` (callers `FeedsView`, `BackgroundRefreshManager` depend on it).

---

## File Structure

- `Yana/Services/AggregationService.swift` — add `FeedFailure`, `lastRunFailures`, `userFacingMessage(for:)`; reset/append logic in `aggregate(feed:)`, `updateAll()`, `update(feed:)`.
- `Yana/Utilities/SyncFailureSummary.swift` (new) — pure summary-line builder.
- `Yana/Views/ArticleReaderView.swift` — `refresh()` sets `appState.errorMessage`; add `.alert`.
- `Yana/Views/Config/FeedsView.swift` — remove `.lineLimit(3)`.
- `Yana/Resources/Localizable.xcstrings` — 4 new strings + German.
- `YanaTests/AggregationServiceTests.swift` — extend (error helper + failure tracking).
- `YanaTests/SyncFailureSummaryTests.swift` (new).

---

## Task 1: Error → user-facing message helper

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: `YanaTests/AggregationServiceTests.swift`

**Interfaces:**
- Produces: `static func userFacingMessage(for error: Error) -> String` on `AggregationService`.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/AggregationServiceTests.swift` inside the `AggregationServiceTests` struct:

```swift
// MARK: - User-facing error messages

@Test func userFacingMessageUsesLocalizedErrorDescription() {
    let error = AggregatorError.missingIdentifier
    #expect(AggregationService.userFacingMessage(for: error) == error.errorDescription)
}

@Test func userFacingMessageUsesURLErrorLocalizedDescription() {
    let error = URLError(.notConnectedToInternet)
    #expect(AggregationService.userFacingMessage(for: error) == error.localizedDescription)
}

@Test func userFacingMessageFallsBackForBareError() {
    struct Bare: Error {}
    #expect(AggregationService.userFacingMessage(for: Bare())
            == String(localized: "An unexpected error occurred."))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests test`
Expected: FAIL — `userFacingMessage` is not a member of `AggregationService`.

- [ ] **Step 3: Implement the helper**

In `Yana/Services/AggregationService.swift`, add this method to the `AggregationService` class (e.g. just after the `init`):

```swift
/// Map an arbitrary error to a clear, non-empty user-facing string.
/// `LocalizedError` (e.g. `AggregatorError`) and Cocoa/URL errors already carry good
/// messages; bare Swift errors otherwise render Foundation's useless synthesized
/// "The operation couldn't be completed. (… error 1.)", so they get a localized fallback.
static func userFacingMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return description
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain || nsError.domain == NSCocoaErrorDomain {
        return error.localizedDescription
    }
    return String(localized: "An unexpected error occurred.")
}
```

- [ ] **Step 4: Use the helper in `aggregate(feed:)`**

In `Yana/Services/AggregationService.swift`, change the `catch` block of `aggregate(feed:)`:

```swift
        } catch {
            feed.lastError = Self.userFacingMessage(for: error)
            return 0
        }
```

(Leave the `notImplemented` guard's `feed.lastError = AggregatorError.notImplemented(...).errorDescription` as-is for now; Task 2 revisits it.)

- [ ] **Step 5: Add localization for the fallback string**

Run this from the repo root to insert the entry into the catalog:

```bash
python3 - <<'PY'
import json
p = "Yana/Resources/Localizable.xcstrings"
d = json.load(open(p))
d["strings"]["An unexpected error occurred."] = {
    "localizations": {"de": {"stringUnit": {
        "state": "translated", "value": "Ein unerwarteter Fehler ist aufgetreten."}}}
}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
PY
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests test`
Expected: PASS (`** TEST SUCCEEDED **`).

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/AggregationService.swift Yana/Resources/Localizable.xcstrings YanaTests/AggregationServiceTests.swift
git commit -m "feat: map sync errors to clear user-facing messages"
```

---

## Task 2: Track per-run failures in AggregationService

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Test: `YanaTests/AggregationServiceTests.swift`

**Interfaces:**
- Consumes: `AggregationService.userFacingMessage(for:)` (Task 1).
- Produces: `struct AggregationService.FeedFailure: Sendable, Equatable { let feedName: String; let message: String }` and `private(set) var lastRunFailures: [FeedFailure]` on `AggregationService`.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/AggregationServiceTests.swift` inside the struct (the `FakeAggregator`/`aggregated` helpers already exist there):

```swift
// MARK: - Per-run failure tracking

@Test func updateAllRecordsFailureWithFeedNameAndMessage() async throws {
    let context = try makeContext()
    let bad = Feed(name: "Bad Feed", aggregatorType: .feedContent, identifier: "bad")
    context.insert(bad)
    let service = AggregationService(context: context) { _, _ in
        FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
    }
    await service.updateAll()

    #expect(service.lastRunFailures.count == 1)
    #expect(service.lastRunFailures.first?.feedName == "Bad Feed")
    #expect(service.lastRunFailures.first?.message == AggregatorError.missingIdentifier.errorDescription)
}

@Test func successfulRunLeavesNoFailures() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let service = AggregationService(context: context) { _, _ in
        FakeAggregator(articles: [self.aggregated("x")])
    }
    await service.updateAll()
    #expect(service.lastRunFailures.isEmpty)
}

@Test func laterSuccessfulRunClearsPriorFailures() async throws {
    final class Toggle: @unchecked Sendable { var fail = true }
    let toggle = Toggle()
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let service = AggregationService(context: context) { _, _ in
        toggle.fail
            ? FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
            : FakeAggregator(articles: [self.aggregated("x")])
    }
    await service.update(feed: feed)
    #expect(service.lastRunFailures.count == 1)
    toggle.fail = false
    await service.update(feed: feed)
    #expect(service.lastRunFailures.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests test`
Expected: FAIL — `lastRunFailures` / `FeedFailure` not found.

- [ ] **Step 3: Add the type and property**

In `Yana/Services/AggregationService.swift`, add near the top of the class (after `var isUpdating = false`):

```swift
    /// A feed that failed during the most recent run.
    struct FeedFailure: Sendable, Equatable {
        let feedName: String
        let message: String
    }

    /// Failures recorded during the most recent `updateAll()` / `update(feed:)`.
    private(set) var lastRunFailures: [FeedFailure] = []
```

- [ ] **Step 4: Reset at run entry points**

In `updateAll()`, add as the first line inside the function body (before `isUpdating = true`):

```swift
        lastRunFailures = []
```

In `update(feed:)`, add as the first line inside the function body (before `isUpdating = true`):

```swift
        lastRunFailures = []
```

- [ ] **Step 5: Record failures in `aggregate(feed:)`**

In `aggregate(feed:)`, update the `notImplemented` guard:

```swift
        guard let aggregator = makeAggregator(config, credentials) else {
            let message = AggregatorError.notImplemented(feed.type).errorDescription ?? ""
            feed.lastError = message
            lastRunFailures.append(FeedFailure(feedName: feed.name, message: message))
            return 0
        }
```

And the `catch` block:

```swift
        } catch {
            let message = Self.userFacingMessage(for: error)
            feed.lastError = message
            lastRunFailures.append(FeedFailure(feedName: feed.name, message: message))
            return 0
        }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat: record per-run feed failures in AggregationService"
```

---

## Task 3: SyncFailureSummary helper

**Files:**
- Create: `Yana/Utilities/SyncFailureSummary.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`
- Create: `YanaTests/SyncFailureSummaryTests.swift`

**Interfaces:**
- Consumes: `AggregationService.FeedFailure` (Task 2).
- Produces: `enum SyncFailureSummary { static func message(for failures: [AggregationService.FeedFailure]) -> String? }`.

- [ ] **Step 1: Create the test file**

Create `YanaTests/SyncFailureSummaryTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
@Suite("SyncFailureSummary")
struct SyncFailureSummaryTests {
    @Test func noFailuresReturnsNil() {
        #expect(SyncFailureSummary.message(for: []) == nil)
    }

    @Test func singleFailureNamesFeedAndMessage() {
        let failure = AggregationService.FeedFailure(feedName: "Heise", message: "boom")
        #expect(SyncFailureSummary.message(for: [failure])
                == String(localized: "Couldn't update \u{201C}Heise\u{201D}: boom"))
    }

    @Test func multipleFailuresReturnCount() {
        let failures = [
            AggregationService.FeedFailure(feedName: "A", message: "x"),
            AggregationService.FeedFailure(feedName: "B", message: "y"),
        ]
        #expect(SyncFailureSummary.message(for: failures)
                == String(localized: "2 feeds couldn't be updated. Check Feeds in Configuration."))
    }
}
```

- [ ] **Step 2: Regenerate project and run tests to verify they fail**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/SyncFailureSummaryTests test`
Expected: FAIL — `SyncFailureSummary` not found.

- [ ] **Step 3: Create the implementation**

Create `Yana/Utilities/SyncFailureSummary.swift`:

```swift
import Foundation

/// Builds a single user-facing summary line for a batch of failed feed updates.
enum SyncFailureSummary {
    static func message(for failures: [AggregationService.FeedFailure]) -> String? {
        switch failures.count {
        case 0:
            return nil
        case 1:
            let failure = failures[0]
            return String(localized: "Couldn't update \u{201C}\(failure.feedName)\u{201D}: \(failure.message)")
        default:
            return String(localized: "\(failures.count) feeds couldn't be updated. Check Feeds in Configuration.")
        }
    }
}
```

- [ ] **Step 4: Add localization for the two summary strings**

```bash
python3 - <<'PY'
import json
p = "Yana/Resources/Localizable.xcstrings"
d = json.load(open(p))
d["strings"]["Couldn't update “%@”: %@"] = {
    "localizations": {"de": {"stringUnit": {
        "state": "translated",
        "value": "„%@“ konnte nicht aktualisiert werden: %@"}}}
}
d["strings"]["%lld feeds couldn't be updated. Check Feeds in Configuration."] = {
    "localizations": {"de": {"stringUnit": {
        "state": "translated",
        "value": "%lld Feeds konnten nicht aktualisiert werden. Details unter „Feeds“ in der Konfiguration."}}}
}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
PY
```

- [ ] **Step 5: Regenerate project and run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/SyncFailureSummaryTests test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Utilities/SyncFailureSummary.swift Yana/Resources/Localizable.xcstrings YanaTests/SyncFailureSummaryTests.swift Yana.xcodeproj
git commit -m "feat: add SyncFailureSummary for reader failure messages"
```

---

## Task 4: Surface failures in the reader

**Files:**
- Modify: `Yana/Views/ArticleReaderView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AggregationService.lastRunFailures` (Task 2), `SyncFailureSummary.message(for:)` (Task 3), `AppState.errorMessage` (existing).

This task is SwiftUI wiring; verification is a successful build (no unit test for the view).

- [ ] **Step 1: Set `errorMessage` after refresh**

In `Yana/Views/ArticleReaderView.swift`, replace `refresh()`:

```swift
    private func refresh() async {
        let service = AggregationService(context: modelContext)
        await service.updateAll()
        appState.errorMessage = SyncFailureSummary.message(for: service.lastRunFailures)
    }
```

- [ ] **Step 2: Add the alert**

In `Yana/Views/ArticleReaderView.swift`, add this modifier to the `NavigationStack`'s content, immediately after the existing `.sheet(isPresented: $appState.showFilter, ...)` line (around line 81):

```swift
            .alert("Update Failed", isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.errorMessage ?? "")
            }
```

- [ ] **Step 3: Add localization for the alert title**

```bash
python3 - <<'PY'
import json
p = "Yana/Resources/Localizable.xcstrings"
d = json.load(open(p))
d["strings"]["Update Failed"] = {
    "localizations": {"de": {"stringUnit": {
        "state": "translated", "value": "Aktualisierung fehlgeschlagen"}}}
}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
PY
```

(`OK` already exists in the catalog — do not re-add it.)

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/ArticleReaderView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat: show an alert in the reader when feeds fail to sync"
```

---

## Task 5: Uncap the Feeds-list error text

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`

This is a one-line layout change; verification is a successful build.

- [ ] **Step 1: Remove the line limit**

In `Yana/Views/Config/FeedsView.swift`, in the `row(_:)` function, delete the `.lineLimit(3)` line from the error `Text` so the block reads:

```swift
            if let error = lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "fix: show the full feed error message in the Feeds list"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Manual smoke (optional but recommended):** Launch the app, add a `feedContent` feed with an unreachable URL (e.g. `https://does-not-exist.invalid/feed.xml`), pull to refresh in the reader → an "Update Failed" alert appears naming the feed and reason. Open Configuration → Feeds → the same feed shows the triangle with the full error text below.
