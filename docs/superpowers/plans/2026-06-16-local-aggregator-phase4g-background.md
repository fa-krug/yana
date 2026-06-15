# Phase 4g — Background Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add best-effort periodic on-device aggregation via a `BGAppRefreshTask`. Register a background task (id `de.fa-krug.Yana.background-refresh`), schedule it on launch at `AppSettings.backgroundInterval`, and run `AggregationService.updateAll()` in the handler — then reschedule. Pull-down on the reader remains the primary trigger; the background path is best-effort and fails silently.

**Architecture:** A `@MainActor` `BackgroundRefreshManager` owns the identifier, an interval provider, and a `ModelContainer`. `register()` wires `BGTaskScheduler.shared.register` once at launch; `schedule(after:)` submits a `BGAppRefreshTaskRequest` with `earliestBeginDate = now + interval`; `handle(task:)` reschedules, spins up an `AggregationService` on the main actor, awaits `updateAll()`, and calls `task.setTaskCompleted`. Because `BGTaskScheduler` cannot run under XCTest, the testable surface is extracted into a **pure date helper** (`nextBeginDate(from:interval:)`) and a **service-agnostic runner** (`runRefresh(service:)`) that just awaits `updateAll()`. The app entry point gains a `UIApplicationDelegateAdaptor` so `register()` runs before launch finishes (the system requirement), with the first `schedule()` kicked off from there.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), BackgroundTasks, SwiftData, Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§6).

**Depends on:** Phase 4a (`AggregationService` with `@MainActor`, `init(context:makeAggregator:now:)`, `updateAll()`).

---

## File Structure

- Create `Yana/Services/BackgroundRefreshManager.swift` — the manager: identifier, interval provider, `register()` / `schedule(after:)` / `handle(task:)`, plus the pure `nextBeginDate(from:interval:)` and the injectable `runRefresh(service:)`.
- Modify `Yana/YanaApp.swift` — add a `UIApplicationDelegateAdaptor` `AppDelegate` that builds the manager from the shared `ModelContainer`, registers the task, and schedules the first run; pass the same container into the SwiftUI scene.
- Modify `Yana/Info-iOS.plist` — add `BGTaskSchedulerPermittedIdentifiers` (array with the id) and extend `UIBackgroundModes` with `processing` (alongside the existing `fetch`).
- Create `YanaTests/BackgroundRefreshManagerTests.swift` — unit-test the pure date math and the `runRefresh` → `updateAll()` wiring against an in-memory service.

Build/test commands used throughout:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To run a single suite, append `-only-testing:YanaTests/<SuiteType>`.

> **Testability note:** `BGTaskScheduler.register`, `.submit`, and live `BGTask` execution cannot run under XCTest (they require a real app process launched by the system). We therefore do **not** test registration or submission directly. Instead we unit-test the two extracted, side-effect-free seams — `nextBeginDate(from:interval:)` and `runRefresh(service:)` — which carry all the logic worth covering.

---

## Task 1: Pure schedule math — `nextBeginDate(from:interval:)`

**Files:**
- Create: `Yana/Services/BackgroundRefreshManager.swift`
- Test: `YanaTests/BackgroundRefreshManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/BackgroundRefreshManagerTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("BackgroundRefreshManager")
struct BackgroundRefreshManagerTests {
    @Test func nextBeginDateAddsIntervalToReference() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let result = BackgroundRefreshManager.nextBeginDate(from: now, interval: 1800)
        #expect(result == now.addingTimeInterval(1800))
    }

    @Test func nextBeginDateClampsNonPositiveIntervalToMinimum() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Zero or negative intervals would let iOS run immediately/never; clamp to the floor.
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: 0)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: -500)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshManagerTests`
Expected: FAIL — `cannot find 'BackgroundRefreshManager' in scope`.

- [ ] **Step 3: Create the manager with the pure helper**

Create `Yana/Services/BackgroundRefreshManager.swift`:

```swift
import BackgroundTasks
import Foundation
import SwiftData

/// Best-effort periodic aggregation via `BGAppRefreshTask`. Registered once at launch,
/// scheduled at `AppSettings.backgroundInterval`, and re-scheduled after every run.
/// Pull-down on the reader remains the primary trigger; this path fails silently.
@MainActor
final class BackgroundRefreshManager {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in `Info-iOS.plist`.
    static let taskIdentifier = "de.fa-krug.Yana.background-refresh"

    /// iOS will not honour an earliest-begin sooner than a few minutes; clamp to a safe floor.
    static let minimumInterval: TimeInterval = 60

    private let container: ModelContainer
    private let intervalProvider: @MainActor () -> TimeInterval
    private let now: () -> Date

    init(
        container: ModelContainer,
        intervalProvider: @escaping @MainActor () -> TimeInterval = { AppSettings().backgroundInterval },
        now: @escaping () -> Date = { .now }
    ) {
        self.container = container
        self.intervalProvider = intervalProvider
        self.now = now
    }

    /// Pure: the earliest begin date for the next request. Clamps non-positive intervals
    /// to `minimumInterval` so a misconfigured setting never produces an invalid request.
    static func nextBeginDate(from reference: Date, interval: TimeInterval) -> Date {
        let clamped = interval > 0 ? interval : minimumInterval
        return reference.addingTimeInterval(clamped)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshManagerTests`
Expected: PASS (both date tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift YanaTests/BackgroundRefreshManagerTests.swift
git commit -m "feat: BackgroundRefreshManager pure schedule math"
```

---

## Task 2: Injectable runner — `runRefresh(service:)` awaits `updateAll()`

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift`
- Test: `YanaTests/BackgroundRefreshManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Append these to the `BackgroundRefreshManagerTests` suite in `YanaTests/BackgroundRefreshManagerTests.swift` (inside the `struct`, after the date tests):

```swift
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Fake aggregator returning one canned article (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }

    @Test func runRefreshAwaitsUpdateAllAndImports() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)

        let article = AggregatedArticle(
            title: "x1", identifier: "x1", url: "x1",
            rawContent: "", content: "c", date: .now, author: "", iconURL: nil
        )
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [article])
        }

        await BackgroundRefreshManager.runRefresh(service: service)

        #expect(service.isUpdating == false)
        #expect(feed.articles.count == 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshManagerTests`
Expected: FAIL — `type 'BackgroundRefreshManager' has no member 'runRefresh'`.

- [ ] **Step 3: Add the runner**

In `Yana/Services/BackgroundRefreshManager.swift`, add this static method inside the class (after `nextBeginDate`):

```swift
    /// The work performed for one background run, isolated from `BGTask` so it can be
    /// unit-tested against an in-memory `AggregationService`. Errors are swallowed by the
    /// caller (`handle(task:)`) — a failed background run must never crash the app.
    static func runRefresh(service: AggregationService) async {
        await service.updateAll()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshManagerTests`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift YanaTests/BackgroundRefreshManagerTests.swift
git commit -m "feat: testable runRefresh seam awaiting updateAll"
```

---

## Task 3: `register()`, `schedule(after:)`, and `handle(task:)`

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift`

> No new unit tests here: these methods call `BGTaskScheduler` directly, which is untestable under XCTest. Their logic delegates to the already-tested `nextBeginDate` and `runRefresh`. We verify they compile (build) and are wired in Task 5.

- [ ] **Step 1: Add the BGTask plumbing**

In `Yana/Services/BackgroundRefreshManager.swift`, add these methods inside the class (after `runRefresh`):

```swift
    /// Register the launch handler. MUST be called before the app finishes launching
    /// (from the app delegate), exactly once per process.
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(task: refreshTask)
        }
    }

    /// Submit the next refresh request. Best-effort: submission failures are ignored
    /// (e.g. when running in the simulator or when the system declines).
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.nextBeginDate(from: now(), interval: intervalProvider())
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Run one background refresh, then reschedule. Always completes the task and never
    /// throws out — a background failure must be silent (spec §6).
    func handle(task: BGAppRefreshTask) {
        // Re-arm immediately so the chain continues even if this run is cut short.
        schedule()

        let work = Task { @MainActor in
            let service = AggregationService(context: container.mainContext)
            await Self.runRefresh(service: service)
            task.setTaskCompleted(success: true)
        }

        // Honour the system's expiration: cancel the run and mark it incomplete.
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the manager suite to confirm no regression**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshManagerTests`
Expected: PASS (the three existing tests; the new methods are not directly tested).

- [ ] **Step 4: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift
git commit -m "feat: register/schedule/handle BGAppRefreshTask wiring"
```

---

## Task 4: Info.plist — permitted identifier + background modes

**Files:**
- Modify: `Yana/Info-iOS.plist`

- [ ] **Step 1: Add `BGTaskSchedulerPermittedIdentifiers` and extend `UIBackgroundModes`**

In `Yana/Info-iOS.plist`, replace the existing `UIBackgroundModes` array:

```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>fetch</string>
	</array>
```

with both the extended modes and the permitted-identifiers array (place the new `BGTaskSchedulerPermittedIdentifiers` key immediately after the `UIBackgroundModes` block):

```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>fetch</string>
		<string>processing</string>
	</array>
	<key>BGTaskSchedulerPermittedIdentifiers</key>
	<array>
		<string>de.fa-krug.Yana.background-refresh</string>
	</array>
```

> The identifier string must exactly equal `BackgroundRefreshManager.taskIdentifier`. `fetch` covers the `BGAppRefreshTask`; `processing` is added so a future `BGProcessingTask` (heavier refresh) can be introduced without another plist round-trip.

- [ ] **Step 2: Regenerate the project and build**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```
Expected: project regenerated; BUILD SUCCEEDED. (`Info-iOS.plist` is referenced via `INFOPLIST_FILE`; no `project.yml` change is required for these keys.)

- [ ] **Step 3: Commit**

```bash
git add Yana/Info-iOS.plist
git commit -m "chore: declare background-refresh task id + processing mode in Info.plist"
```

---

## Task 5: Wire `register()` + first `schedule()` into app launch

**Files:**
- Modify: `Yana/YanaApp.swift`

> `BGTaskScheduler.register(forTaskWithIdentifier:…)` must be called **before** the app finishes launching. SwiftUI's `App.init` runs too early/unreliably for this, so we add a `UIApplicationDelegateAdaptor`. The delegate and the scene must share **one** `ModelContainer`, so we lift the container out of `YanaApp` into a single shared instance.

- [ ] **Step 1: Replace `Yana/YanaApp.swift`**

Replace the entire contents of `Yana/YanaApp.swift` with:

```swift
import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit

/// Single shared SwiftData container, used by both the app delegate (for background
/// refresh) and the SwiftUI scene.
enum AppContainer {
    static let shared: ModelContainer = {
        do {
            let container = try ModelContainer(for: Feed.self, Tag.self, Article.self)
            Tag.ensureBuiltIns(in: container.mainContext)
            try? container.mainContext.save()
            return container
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()
}

/// Registers the background-refresh task before launch completes and schedules the first run.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private lazy var backgroundRefresh = BackgroundRefreshManager(container: AppContainer.shared)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            backgroundRefresh.register()
            backgroundRefresh.schedule()
        }
        return true
    }
}

@main
struct YanaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .modelContainer(AppContainer.shared)
    }
}
```

- [ ] **Step 2: Regenerate (no-op for files) and build**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```
Expected: BUILD SUCCEEDED. The scene now uses `AppContainer.shared`; the delegate registers and schedules on launch.

- [ ] **Step 3: Run the full suite to confirm nothing regressed**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. (No existing test references the old inline `container` property on `YanaApp`; views continue to read SwiftData via `@Query` / `@Environment(\.modelContext)`.)

- [ ] **Step 4: Commit**

```bash
git add Yana/YanaApp.swift
git commit -m "feat: register + schedule background refresh on app launch"
```

---

## Notes for later phases

- `schedule()` reads `AppSettings().backgroundInterval` (default 1800s) via the interval provider; a future Settings toggle to disable background refresh can short-circuit `schedule()` (e.g. submit nothing when the user opts out).
- `handle(task:)` constructs an `AggregationService` with the **default** registry factory, so once Phase 4b+ populates `AggregatorRegistry`, background runs fetch real content with no further wiring.
- A heavier `BGProcessingTask` (e.g. for AI post-processing or image cache compaction) can be added under the already-declared `processing` background mode with its own identifier.
- Manual verification on device/simulator (not part of CI): launch once, then trigger via the debugger —
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"de.fa-krug.Yana.background-refresh"]` — and confirm `updateAll()` runs and reschedules.

---

## Self-Review

**Spec coverage (§6):** `BGAppRefreshTask` id `de.fa-krug.Yana.background-refresh` (Task 1 constant, Task 4 plist), registered in `Info-iOS.plist` `BGTaskSchedulerPermittedIdentifiers` (Task 4), handler builds the service + runs `updateAll()` (Task 3 `handle` + Task 2 `runRefresh`), reschedules at `AppSettings.backgroundInterval` (Task 3 `schedule` + Task 1 `nextBeginDate` + interval provider), first scheduled on launch (Task 5), best-effort with silent errors (`try?` on submit, swallowed run errors, always `setTaskCompleted`). Pull-down remains the primary trigger (untouched). All covered.

**Testability:** the two seams worth covering are pure/injectable and unit-tested — `nextBeginDate(from:interval:)` (date math + clamp) and `runRefresh(service:)` (awaits `updateAll()` against an in-memory service with a fake aggregator). `BGTaskScheduler.register`/`submit` and live `BGTask` execution are intentionally **not** tested (impossible under XCTest); they are covered by build verification and the launch wiring.

**Placeholders:** none — every step shows complete Swift / XML or an exact command + expected result.

**Type consistency:** `BackgroundRefreshManager.taskIdentifier` (`"de.fa-krug.Yana.background-refresh"`) matches the plist identifier and the spec verbatim. The manager uses the Phase 4a `AggregationService(context:makeAggregator:now:)` initializer (default factory) and its `updateAll()` / `isUpdating` API. `intervalProvider` defaults to `AppSettings().backgroundInterval` (the actual property name, `TimeInterval`, default 1800.0). `AppContainer.shared` is the single `ModelContainer` shared by `AppDelegate` and the scene. `Yana.Tag` is namespaced in tests to avoid collision with SwiftData/Foundation `Tag`, and the `FakeAggregator`/`AggregatedArticle` shapes match Phase 4a's.
