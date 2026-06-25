# Cold-start: Indexes + Deferred Tag Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut cold-start cost by adding SwiftData indexes to `Article` and moving the synchronous tag bootstrap off the launch thread.

**Architecture:** Two independent changes. (1) Add `#Index<Article>([\.createdAt], [\.identifier])` so the cold-path fetches stop being full table scans. (2) Make `Tag.ensureBuiltIns` report whether it inserted, and run it (with a conditional save) in a post-launch task instead of synchronously in `didFinishLaunchingWithOptions` — `BGTaskScheduler` registration stays synchronous.

**Tech Stack:** Swift 6, SwiftData, SwiftUI/UIKit, Swift Testing.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` on UI/SwiftData-main types.
- Platform: iOS 26.0+.
- Unit tests: Swift Testing (`import Testing`), `@MainActor`, in-memory
  `ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations:)` with
  `isStoredInMemoryOnly: true`.
- `Tag` is referenced as `Yana.Tag` in tests (disambiguates from Swift's `Tag`).
- No user-facing strings → no `Localizable.xcstrings` changes.
- All changes edit existing files (no new files), so `xcodegen generate` is not required;
  running it is harmless.
- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test (full): `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- Single suite: append `-only-testing:YanaTests/Tag`
- Full-suite health check: the Swift Testing reporter prints `Test run with N tests in M suites passed`
  (currently ~559 tests / 114 suites); the XCTest `Executed 1 test` line is only the UI test.
  Confirm both the Swift Testing summary and `TEST SUCCEEDED`.

---

### Task 1: `ensureBuiltIns` reports whether it inserted

**Files:**
- Modify: `Yana/Models/Tag.swift` (the `ensureBuiltIns(in:)` static method, ~line 31)
- Test: `YanaTests/TagTests.swift` (add a `@Test` to the existing `TagTests` suite)

**Interfaces:**
- Consumes: nothing new.
- Produces: `@discardableResult static func ensureBuiltIns(in context: ModelContext) -> Bool`
  — returns `true` when it inserted the built-in Starred tag, `false` when one already existed.
  `@discardableResult` keeps existing call sites that ignore the result compiling.

- [ ] **Step 1: Write the failing test**

In `YanaTests/TagTests.swift`, add this `@Test` inside the `TagTests` struct (after `seedsStarredOnceAndIsIdempotent`):

```swift
    @Test func ensureBuiltInsReportsWhetherInserted() throws {
        let context = try makeContext()
        #expect(Yana.Tag.ensureBuiltIns(in: context) == true)   // first call inserts
        #expect(Yana.Tag.ensureBuiltIns(in: context) == false)  // already present
        let starred = try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn }))
        #expect(starred.count == 1)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/Tag`
Expected: FAIL — the current `ensureBuiltIns` returns `Void`, so `== true` does not type-check / the test cannot pass.

- [ ] **Step 3: Change `ensureBuiltIns` to return `Bool`**

In `Yana/Models/Tag.swift`, replace the method:

```swift
    static func ensureBuiltIns(in context: ModelContext) {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }
        context.insert(Tag(name: starredName, colorHex: "#F5C518", isBuiltIn: true, sortOrder: -1))
    }
```

with:

```swift
    /// Inserts the built-in Starred tag if missing. Returns `true` when it inserted (so the
    /// caller can save only when something changed), `false` when one already existed.
    @discardableResult
    static func ensureBuiltIns(in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return false }
        context.insert(Tag(name: starredName, colorHex: "#F5C518", isBuiltIn: true, sortOrder: -1))
        return true
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/Tag`
Expected: PASS (including the existing `seedsStarredOnceAndIsIdempotent`, which ignores the new return value via `@discardableResult`).

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/Tag.swift YanaTests/TagTests.swift
git commit -m "feat(models): ensureBuiltIns reports whether it inserted"
```

---

### Task 2: Defer the tag bootstrap off the launch thread

**Files:**
- Modify: `Yana/YanaApp.swift` (`AppDelegate.application(_:didFinishLaunchingWithOptions:)`, ~lines 26-38)

**Interfaces:**
- Consumes: `Tag.ensureBuiltIns(in:) -> Bool` (Task 1); `AppContainer.shared`;
  `backgroundRefresh.register()` / `.schedule()`.
- Produces: nothing new.

- [ ] **Step 1: Move the tag work into a post-launch task with a conditional save**

In `Yana/YanaApp.swift`, replace the body of `application(_:didFinishLaunchingWithOptions:)`:

```swift
        // Bootstrap built-in tags on first launch (idempotent).
        Tag.ensureBuiltIns(in: AppContainer.shared.mainContext)
        try? AppContainer.shared.mainContext.save()

        backgroundRefresh.register()
        backgroundRefresh.schedule()
        return true
```

with:

```swift
        // BGTaskScheduler requires registration before launch completes — keep it synchronous.
        backgroundRefresh.register()
        backgroundRefresh.schedule()

        // Tag bootstrap is idempotent and not needed before first paint (the Starred tag is only
        // consulted on a user star action), so move its fetch + save off the synchronous launch
        // path. Save only when an insert actually happened — no per-launch context flush.
        Task { @MainActor in
            let context = AppContainer.shared.mainContext
            if Tag.ensureBuiltIns(in: context) {
                try? context.save()
            }
        }
        return true
```

Also update the doc comment on the `AppContainer` enum (~line 10-11) if it still claims the
bootstrap "runs in the app delegate before any UI is shown" — change it to note the tag
bootstrap now runs in a post-launch main-actor task. Exact replacement:

Find:
```swift
/// `ModelContainer` is `Sendable`, so the static let is safe to access from any
/// isolation domain. The main-actor bootstrap (`ensureBuiltIns` + save) runs in the
/// app delegate before any UI is shown.
```
Replace with:
```swift
/// `ModelContainer` is `Sendable`, so the static let is safe to access from any
/// isolation domain. The tag bootstrap (`ensureBuiltIns` + conditional save) runs in a
/// post-launch main-actor task so it does not block `didFinishLaunchingWithOptions`.
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full suite (no regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: `Test run with N tests in M suites passed` + `TEST SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Yana/YanaApp.swift
git commit -m "perf(launch): defer tag bootstrap off the synchronous launch path"
```

---

### Task 3: Add SwiftData indexes to `Article`

**Files:**
- Modify: `Yana/Models/Article.swift` (add the `#Index` macro inside the `@Model`)

**Interfaces:**
- Consumes: nothing new.
- Produces: index metadata only — no Swift symbols other tasks reference.

- [ ] **Step 1: Add the `#Index` macro**

In `Yana/Models/Article.swift`, add the macro as the first line inside the `@Model final class Article {` body, immediately before `var title: String = ""`:

```swift
    // Cold-path fetches sort/filter by these: createdAt drives the anchor window, full index
    // load, and fetchNewest; identifier drives the one-row fetchByIdentifier lookup. Without an
    // index each is a full table scan over the retained library. Single-column (no query filters
    // on both together). Additive metadata — SwiftData handles it via lightweight migration.
    #Index<Article>([\.createdAt], [\.identifier])
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (the `#Index` macro resolves; `Article` still conforms to `PersistentModel`).

- [ ] **Step 3: Run the full suite (queries still correct + store opens)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: `Test run with N tests in M suites passed` + `TEST SUCCEEDED`. In particular the
ordering/resolution suites (timeline ordering, article resolution, upsert) must still pass —
they exercise the `createdAt` sort and `identifier` lookup the indexes back.

- [ ] **Step 4: Commit**

```bash
git add Yana/Models/Article.swift
git commit -m "perf(models): index Article.createdAt and identifier for cold-path fetches"
```

---

### Task 4: Manual verification — existing store opens after migration

**Files:** none.

- [ ] **Step 1: Confirm a pre-existing store survives the index migration**

On a simulator/device that already has the app installed with articles (a store created
before this change), install the new build over it (do not delete the app first). Launch and
confirm: the app opens to the reader, the timeline shows existing articles in the same order,
and there is no crash or data loss. This verifies the additive `#Index` migration applies
cleanly to a populated store.

- [ ] **Step 2: Confirm starring still works after deferred bootstrap**

Cold-launch the app, then star and unstar an article. Confirm the Starred built-in tag is
present and toggling works (verifying the post-launch tag bootstrap completed).

---

## Self-Review

**Spec coverage:**
- Indexes on `createdAt` + `identifier` (single-column, lightweight migration) → Task 3. ✓
- `ensureBuiltIns` returns `Bool` (`@discardableResult`) → Task 1. ✓
- Deferred tag bootstrap in a post-launch task; `register()/schedule()` stay synchronous;
  conditional save → Task 2. ✓
- Existing-store-opens migration risk → Task 4 (manual). ✓
- `ensureBuiltIns` return-value test → Task 1. ✓
- Existing query suites still pass (index regression) → Task 3 step 3. ✓
- No user-facing strings → confirmed, no localization task. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `ensureBuiltIns -> Bool` defined in Task 1 is consumed in Task 2's
`if Tag.ensureBuiltIns(in: context) { … }`. `#Index` macro (Task 3) introduces no symbols
other tasks reference. Consistent. ✓
