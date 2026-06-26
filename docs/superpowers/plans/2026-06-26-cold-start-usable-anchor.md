# Cold-Start Fully-Usable Anchored Reader — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the anchored reader visible, scrollable, and swipeable as fast as possible on cold start by front-loading the WebKit document load, deferring the full DB reconcile, and building the pager pre-positioned on the anchor in a single pass.

**Architecture:** Three coordinated, low-risk changes that keep the existing launch-warmup → pager-adoption hand-off intact: (1) start `ReaderWarmup` in `AppDelegate.didFinishLaunching` with pre-window re-parenting; (2) split `ArticleStore.bootstrap` so it publishes the fast dataset and yields before the full reconcile; (3) resolve the filtered list + anchor index together so `ReaderHostView` is built once, already positioned. A pure `TimelineBootstrap.resolve` helper carries the positioning logic and is the main unit-tested seam.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI + UIKit reader bridge, SwiftData, WebKit, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform: iOS 26.0+ (iPhone and iPad). `TARGETED_DEVICE_FAMILY "1,2"`.
- Swift 6 strict concurrency; reader/UI types are `@MainActor`.
- No new user-facing strings in this work; if any are added they MUST be localized in `Yana/Resources/Localizable.xcstrings` for `en` + `de` (`"state": "translated"`). (None expected.)
- Source of truth is SwiftData via `ArticleStore`; views read `ArticleSummary`, never per-view `@Query` for the timeline.
- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- After adding/removing files, run `xcodegen generate` before building (the `Yana` folder is auto-included).
- Measured verification uses the existing `StartupTrace` (subsystem `de.fa-krug.Yana`, category `startup`) and `DebugSeed` (`YANA_SEED_ARTICLES`). Stream with:
  `xcrun simctl spawn booted log stream --level debug --style compact --predicate 'subsystem == "de.fa-krug.Yana" AND category == "startup"'`

---

### Task 0: Commit the measurement baseline

The working tree already contains the `StartupTrace` instrumentation, the DEBUG-only `DebugSeed` fixture, and the trace hooks added during investigation (`ReaderHostView`, `ReaderWarmup`, `ReaderWebViewController`, `ArticleStore`, `YanaApp`). Commit them as the baseline the rest of the plan builds and measures against.

**Files:**
- Already created: `Yana/Utilities/StartupTrace.swift`, `Yana/Utilities/DebugSeed.swift`
- Already modified: `Yana/Reader/ReaderHostView.swift`, `Yana/Reader/ReaderWarmup.swift`, `Yana/Reader/ReaderWebViewController.swift`, `Yana/Services/ArticleStore.swift`, `Yana/YanaApp.swift`

- [ ] **Step 1: Confirm the project builds**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests pass (Swift Testing reports ~559; the single XCTest UI test also runs).

- [ ] **Step 3: Commit the baseline**

```bash
git add Yana/Utilities/StartupTrace.swift Yana/Utilities/DebugSeed.swift \
        Yana/Reader/ReaderHostView.swift Yana/Reader/ReaderWarmup.swift \
        Yana/Reader/ReaderWebViewController.swift Yana/Services/ArticleStore.swift \
        Yana/YanaApp.swift Yana.xcodeproj
git commit -m "chore(startup): add cold-start timing instrumentation + debug seed"
```

---

### Task 1: Defer the full DB reconcile in `ArticleStore.bootstrap` (Lever 2)

Split `bootstrap()` so it publishes the fast dataset and flips `hasLoaded` in a dedicated method, then yields before the full reconcile so SwiftUI can build the pager first.

**Files:**
- Modify: `Yana/Services/ArticleStore.swift` (the `bootstrap()` method, ~lines 112–125)
- Test: `YanaTests/ArticleStoreTests.swift`

**Interfaces:**
- Consumes: `ArticleStore(container:cache:anchorProvider:)`, `SummaryIndexCache`, `ArticleSummaryLoader.loadWindow(around:radius:)`, `Self.windowRadius` (= 25).
- Produces: `func publishFastDataset() async` — publishes the cache (when present) else the anchor-centered window (`2*windowRadius+1` items) into `summaries` and sets `hasLoaded = true`, WITHOUT reconciling to the full DB. `bootstrap()` still ends with the full index published.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/ArticleStoreTests.swift` inside the `ArticleStoreTests` struct:

```swift
@Test func publishFastDatasetServesWindowWithoutReconcile() async throws {
    let container = try makeContainer()
    seed(100, into: container.mainContext)            // a0…a99
    try container.mainContext.save()

    let store = ArticleStore(
        container: container,
        cache: tempCache(),                           // cold cache → anchor window path
        anchorProvider: { "a50" }
    )
    await store.publishFastDataset()

    #expect(store.hasLoaded == true)
    #expect(store.summaries.count == 51)              // 2*radius+1, NOT the full 100
    #expect(store.summaries.first?.identifier == "a25")
    #expect(store.summaries.last?.identifier == "a75")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStoreTests/publishFastDatasetServesWindowWithoutReconcile`
Expected: FAIL — `publishFastDataset` does not exist (compile error).

- [ ] **Step 3: Implement the split**

In `Yana/Services/ArticleStore.swift`, replace the `bootstrap()` method with:

```swift
/// Cold-start path: publish a fast first dataset (disk cache when present, else an
/// anchor-centered DB window) and flip `hasLoaded`, yield so SwiftUI can build the pager off
/// it, then reconcile to the authoritative full load.
func bootstrap() async {
    await publishFastDataset()
    // Let the reader build + adopt the warmed web view before the full DB fetch competes for
    // the main thread; `fullLoad` self-heals the displayed position by identifier, so deferring
    // it never strands the anchor.
    await Task.yield()
    await fullLoad()
}

/// Publish the fast first dataset (disk cache, else an anchor-centered DB window) and flip
/// `hasLoaded`. Does NOT reconcile to the full DB — `bootstrap()` does that after a yield.
func publishFastDataset() async {
    if let cached = await StartupTrace.measure("ArticleStore.cache.load", { await cache.load() }) {
        summaries = cached
    } else {
        let window = await StartupTrace.measure("ArticleStore.loadWindow") { () -> [ArticleSummary] in
            let loader = ArticleSummaryLoader(modelContainer: container)
            return (try? await loader.loadWindow(
                around: anchorProvider(), radius: Self.windowRadius
            )) ?? []
        }
        summaries = window
    }
    hasLoaded = true
    StartupTrace.event("ArticleStore.hasLoaded")
}
```

- [ ] **Step 4: Run the new test + the existing bootstrap tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStoreTests`
Expected: PASS — including `bootstrapServesCacheThenReconcilesToDB` and `bootstrapUsesAnchorWindowWhenCacheCold` (final reconciled state unchanged by the yield).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift YanaTests/ArticleStoreTests.swift
git commit -m "perf(launch): publish fast dataset then yield before full reconcile"
```

---

### Task 2: Pure `TimelineBootstrap.resolve` helper (Lever 3 logic)

A single pure function that filters the timeline and resolves the saved anchor to an index, so the reader can be built positioned on the anchor in one pass. Generic over the timeline protocols so it unit-tests without SwiftData.

**Files:**
- Create: `Yana/Utilities/TimelineBootstrap.swift`
- Test: `YanaTests/TimelineBootstrapTests.swift`

**Interfaces:**
- Consumes: `TagFilter.apply(to:disabledTagNames:includeUntagged:)`, `FeedFilter.apply(to:disabledFeedNames:)`, `TimelineAnchor.index(for:in:)`, protocols `TimelineFilterable`, `TimelineIdentifiable`.
- Produces: `TimelineBootstrap.resolve(summaries:disabledTagNames:includeUntagged:disabledFeedNames:anchorIdentifier:) -> (articles: [T], anchorIndex: Int)` for `T: TimelineFilterable & TimelineIdentifiable`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/TimelineBootstrapTests.swift`:

```swift
import Testing
@testable import Yana

struct TimelineBootstrapTests {
    private struct Item: TimelineFilterable, TimelineIdentifiable {
        let identifier: String
        let filterTagNames: [String]
        let filterFeedName: String?
        init(_ id: String, tags: [String] = ["t"], feed: String? = "f") {
            identifier = id; filterTagNames = tags; filterFeedName = feed
        }
    }

    @Test func positionsOnSavedAnchor() {
        let items = [Item("a"), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["a", "b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func fallsBackToNewestWhenAnchorMissing() {
        let items = [Item("a"), Item("b")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], anchorIdentifier: "ghost"
        )
        #expect(r.anchorIndex == 1)   // newest = last index
    }

    @Test func anchorIndexIsRelativeToFilteredList() {
        // "a" is filtered out by its tag; anchor "c" must reindex to 1, not 2.
        let items = [Item("a", tags: ["hidden"]), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: ["hidden"], includeUntagged: false,
            disabledFeedNames: [], anchorIdentifier: "c"
        )
        #expect(r.articles.map(\.identifier) == ["b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func emptyInputYieldsZeroIndex() {
        let r = TimelineBootstrap.resolve(
            summaries: [Item](), disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], anchorIdentifier: "x"
        )
        #expect(r.articles.isEmpty)
        #expect(r.anchorIndex == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineBootstrapTests`
Expected: FAIL — `TimelineBootstrap` does not exist.

- [ ] **Step 3: Implement the helper**

Create `Yana/Utilities/TimelineBootstrap.swift`:

```swift
import Foundation

/// Resolves the timeline's first displayed dataset in a single pass: applies the tag + feed
/// filters and resolves the saved anchor to an index within the filtered list. Building the
/// reader from this result positions it on the anchor immediately — no separate post-build
/// repositioning frame.
enum TimelineBootstrap {
    static func resolve<T: TimelineFilterable & TimelineIdentifiable>(
        summaries: [T],
        disabledTagNames: Set<String>,
        includeUntagged: Bool,
        disabledFeedNames: Set<String>,
        anchorIdentifier: String?
    ) -> (articles: [T], anchorIndex: Int) {
        let byTag = TagFilter.apply(
            to: summaries, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged
        )
        let filtered = FeedFilter.apply(to: byTag, disabledFeedNames: disabledFeedNames)
        let index = TimelineAnchor.index(for: anchorIdentifier, in: filtered)
        return (filtered, index)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineBootstrapTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/TimelineBootstrap.swift YanaTests/TimelineBootstrapTests.swift Yana.xcodeproj
git commit -m "feat(timeline): pure helper resolving filtered list + anchor index in one pass"
```

---

### Task 3: Build the reader pre-positioned in `ReaderScreen` (Lever 3 integration)

Use `TimelineBootstrap.resolve` for the first load so the filtered list and the anchor index are set together, before `ReaderHostView` is created — eliminating the `onAppear`→`onChange` repositioning frame. Subsequent updates keep the existing filter-then-reanchor behavior.

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift` (`ReaderScreen`: `recomputeFilter`, `restoreAnchor`, `.onAppear`, `.onChange(of: store.summaries)`, the filter-settings `.onChange` handlers — ~lines 111–195)

**Interfaces:**
- Consumes: `TimelineBootstrap.resolve(...)` (Task 2), `store.summaries`, `settings.disabledTagNames/includeUntagged/disabledFeedNames/timelineAnchorIdentifier`, `appState.currentIndex`, `didRestoreAnchor`.
- Produces: no new external interface; `filteredArticles` + `appState.currentIndex` set consistently.

- [ ] **Step 1: Replace `recomputeFilter` and `restoreAnchor` with a combined timeline-apply path**

In `Yana/Reader/ReaderHostView.swift`, replace the existing `recomputeFilter()` method and the `restoreAnchor()` method with:

```swift
/// Re-filter only (used by tag/feed/untagged setting changes — position is preserved/clamped
/// elsewhere).
private func recomputeFilter() {
    let byTag = TagFilter.apply(
        to: store.summaries,
        disabledTagNames: settings.disabledTagNames,
        includeUntagged: settings.includeUntagged
    )
    filteredArticles = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
}

/// First load: filter + position on the saved anchor in one pass, so the reader is built
/// already on the anchor. Subsequent deliveries refilter and re-resolve the displayed article.
private func applyTimeline() {
    guard !didRestoreAnchor else {
        recomputeFilter()
        reanchorToCurrentArticle()
        return
    }
    let resolved = TimelineBootstrap.resolve(
        summaries: store.summaries,
        disabledTagNames: settings.disabledTagNames,
        includeUntagged: settings.includeUntagged,
        disabledFeedNames: settings.disabledFeedNames,
        anchorIdentifier: settings.timelineAnchorIdentifier
    )
    filteredArticles = resolved.articles
    guard !resolved.articles.isEmpty else { return }   // wait for a non-empty delivery to anchor
    appState.currentIndex = resolved.anchorIndex
    didRestoreAnchor = true
}
```

- [ ] **Step 2: Point `.onAppear` and the summaries `.onChange` at `applyTimeline()`**

In the same file, in `ReaderScreen.body`, update the modifiers. Change `.onAppear`'s first two calls and the summaries `onChange`:

```swift
.onAppear {
    applyTimeline()
    if !settings.hasSeenFullscreenHint, UIDevice.current.userInterfaceIdiom == .phone {
        toast = ToastMessage(text: String(localized: "Tap the title bar to hide the toolbars."))
        settings.hasSeenFullscreenHint = true
    }
}
.onChange(of: store.summaries) { _, _ in
    applyTimeline()
}
.onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter() }
.onChange(of: settings.includeUntagged) { _, _ in recomputeFilter() }
.onChange(of: settings.disabledFeedNames) { _, _ in recomputeFilter() }
```

(The `.onChange(of: settings.*)` handlers are unchanged from today — listed here for context. Do not duplicate them.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run the timeline + store suites to verify no regression**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineBootstrapTests -only-testing:YanaTests/TimelineFilteringTests -only-testing:YanaTests/TimelinePageIndexTests -only-testing:YanaTests/ArticleStoreTests`
Expected: PASS.

- [ ] **Step 5: Measured check — anchor still positions correctly**

Seed and launch (no env var on the measure run):

```bash
DD=$(xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')
xcrun simctl uninstall booted de.fa-krug.Yana 2>/dev/null
xcrun simctl install booted "$DD/Yana.app"
SIMCTL_CHILD_YANA_SEED_ARTICLES=100 xcrun simctl launch booted de.fa-krug.Yana >/dev/null; sleep 5
xcrun simctl terminate booted de.fa-krug.Yana
xcrun simctl launch booted de.fa-krug.Yana >/dev/null
```

Expected: app opens directly on the seeded anchor (`seed://article/50`, "Seeded Article 50"), no visible jump from another article on first paint.

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift
git commit -m "perf(launch): build reader pre-positioned on anchor in a single pass"
```

---

### Task 4: Pre-window start for `ReaderWarmup` (Lever 1, part a)

Make `ReaderWarmup.start()` safe to call before a key window exists: load the HTML immediately (the document load progresses off-window and gates `didFinish`), and parent off-screen into the key window as soon as one is available via a one-shot retry. Required before Task 5 moves the call into `didFinishLaunching`.

**Files:**
- Modify: `Yana/Reader/ReaderWarmup.swift` (the `start()` parenting block, ~lines 69–84, and add a private `parentOffScreen` helper)

**Interfaces:**
- Consumes: `keyWindow()` (existing private helper), `WKWebView`.
- Produces: private `static func parentOffScreen(_ webView: WKWebView, retriesLeft: Int)` — parents the web view off-screen in the key window now, or retries on the next runloop until a window exists (bounded), and is a no-op once the view has a superview (i.e. has been adopted).

- [ ] **Step 1: Replace the parenting block in `start()`**

In `Yana/Reader/ReaderWarmup.swift`, find:

```swift
        // Parent off-screen in the key window so WebKit lays out + composites at the eventual page
        // width (making the adopted paint pixel-correct), without ever being visible. Degrades to an
        // off-window warm (process + parse) if no key window exists yet — paint then completes on adopt.
        if let window = keyWindow() {
            webView.frame = CGRect(x: 0, y: window.bounds.height,
                                   width: window.bounds.width, height: window.bounds.height)
            window.addSubview(webView)
            window.sendSubviewToBack(webView)
        }

        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
        ReaderWarmupStore.shared.store(identifier: article.identifier, html: html, webView: webView)
```

and replace it with:

```swift
        // Start the document load immediately — it progresses (and fires `didFinish`) even before
        // the view is on-window, so kicking it as early as possible front-loads the parse.
        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
        // Parent off-screen in the key window so WebKit lays out + composites at the eventual page
        // width (making the adopted paint pixel-correct), without ever being visible. When the warm
        // runs before the scene has a key window (launch path), retry on the next runloop until one
        // exists; a page adopting the view first makes this a no-op (it then has a superview).
        parentOffScreen(webView)
        ReaderWarmupStore.shared.store(identifier: article.identifier, html: html, webView: webView)
```

- [ ] **Step 2: Add the `parentOffScreen` helper**

In `Yana/Reader/ReaderWarmup.swift`, add next to the existing `keyWindow()` helper:

```swift
    /// Parent the warmed web view off-screen in the key window for pixel-correct pre-paint. If no
    /// key window exists yet (warm kicked from `didFinishLaunching` before the scene connects),
    /// retry on the next runloop, bounded. No-op once the view has a superview — adoption parents
    /// it into the page, and re-adding it here must never fight that.
    private static func parentOffScreen(_ webView: WKWebView, retriesLeft: Int = 8) {
        guard webView.superview == nil else { return }
        if let window = keyWindow() {
            webView.frame = CGRect(x: 0, y: window.bounds.height,
                                   width: window.bounds.width, height: window.bounds.height)
            window.addSubview(webView)
            window.sendSubviewToBack(webView)
            return
        }
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.async { parentOffScreen(webView, retriesLeft: retriesLeft - 1) }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run the warmup suite to verify no regression**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: PASS (pure slot + anchor-resolution tests, unaffected).

- [ ] **Step 5: Measured check — warmup still adopted**

```bash
xcrun simctl launch booted de.fa-krug.Yana >/dev/null   # already seeded from Task 3
```
Stream the startup log during launch; Expected: `warmupTake.HIT` and `anchorVisible(adopted)` still appear (no `MISS`).

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/ReaderWarmup.swift
git commit -m "perf(launch): make ReaderWarmup safe to start before a key window exists"
```

---

### Task 5: Start `ReaderWarmup` in `didFinishLaunching` (Lever 1, part b)

Move the warmup kick from the SwiftUI scene `.task` (~+250–330ms) into `AppDelegate.application(_:didFinishLaunchingWithOptions:)` (~+180ms), right after `ModelContainer` is forced, so the WebKit load starts ~100–150ms earlier. The scene `.task` keeps only `articleStore.start()`.

**Files:**
- Modify: `Yana/YanaApp.swift` (`AppDelegate.application(...)` body and the `WindowGroup` `.task`)

**Interfaces:**
- Consumes: `ReaderWarmup.start()` (Task 4), `articleStore.start()`.
- Produces: no new interface.

- [ ] **Step 1: Add the warmup kick in `didFinishLaunching`**

In `Yana/YanaApp.swift`, in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, after the `backgroundRefresh.schedule()` line, add:

```swift
        // Warm WebKit with the anchor article as early as possible: ModelContainer is already
        // forced (by backgroundRefresh), and starting the document load here — before the scene
        // connects — front-loads the parse/paint vs. kicking it from the scene `.task`.
        ReaderWarmup.start()
```

- [ ] **Step 2: Remove the warmup kick from the scene `.task`**

In `Yana/YanaApp.swift`, in the `WindowGroup`, replace:

```swift
                .task {
                    StartupTrace.event("scene.task.begin")
                    StartupTrace.measure("ReaderWarmup.start") { ReaderWarmup.start() }
                    articleStore.start()
                }
```

with:

```swift
                .task {
                    StartupTrace.event("scene.task.begin")
                    articleStore.start()
                }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Measured check — warmup runs before the scene task, anchor still adopts**

```bash
xcrun simctl launch booted de.fa-krug.Yana >/dev/null
```
Stream the startup log; Expected ordering: `ReaderWarmup.start` (and its `renderHTML`/`makeWebView`) fire BEFORE `scene.task.begin`; `warmupTake.HIT` and `anchorVisible(adopted)` still present.

- [ ] **Step 5: Commit**

```bash
git add Yana/YanaApp.swift
git commit -m "perf(launch): start anchor WebKit warm in didFinishLaunching"
```

---

### Task 6: Before/after measurement + full-suite gate

Validate the combined win and confirm no regression.

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests pass.

- [ ] **Step 2: Capture the after-trace (warm cache, 100 articles)**

```bash
xcrun simctl terminate booted de.fa-krug.Yana 2>/dev/null
xcrun simctl spawn booted log stream --level debug --style compact \
  --predicate 'subsystem == "de.fa-krug.Yana" AND category == "startup"' > /tmp/after.log 2>&1 &
LP=$!; sleep 1; xcrun simctl launch booted de.fa-krug.Yana >/dev/null; sleep 6; kill $LP
grep -E "scene.task.begin|hasLoaded|warmupTake|anchorVisible|ReaderWarmup.start took" /tmp/after.log
```

Expected vs. the ~970ms baseline: `anchorVisible(adopted)` earlier (target: meaningfully below ~970ms in sim, driven by the earlier load + removed gating); `warmupTake.HIT` present.

- [ ] **Step 3: Record the result in the design doc**

Append an "Outcome" section to `docs/superpowers/specs/2026-06-26-cold-start-usable-anchor-design.md` with the before/after `anchorVisible` numbers and a note that a device baseline should be captured to size the real WebKit cost.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-26-cold-start-usable-anchor-design.md
git commit -m "docs(cold-start): record measured before/after outcome"
```

---

## Self-Review

**Spec coverage:**
- Lever 1 (earliest load) → Tasks 4 + 5. ✓
- Lever 2 (defer reconcile) → Task 1. ✓
- Lever 3 (single positioned build) → Tasks 2 + 3. ✓
- Edge cases (anchor filtered out / deleted / empty / theme mismatch) → preserved; covered by existing `discardUnused`, `anchorArticle` fallback, `.empty` state, and the HTML-equality warmup gate (unchanged). Task 3 Step 1 preserves the "wait for a non-empty delivery before anchoring" guard. ✓
- Testing (unit bootstrap, unit anchor index, measured trace, full suite) → Tasks 1, 2, 3, 6. ✓
- Instrumentation retained → Task 0. ✓
- Device-validation caveat → Task 6 Step 3. ✓

**Placeholder scan:** none — every code step shows complete code; commands have expected output.

**Type consistency:** `publishFastDataset()` (Task 1) referenced only in `bootstrap()` and its test. `TimelineBootstrap.resolve(summaries:disabledTagNames:includeUntagged:disabledFeedNames:anchorIdentifier:)` defined in Task 2, consumed identically in Task 3. `parentOffScreen(_:retriesLeft:)` defined and called within Task 4. `ReaderWarmup.start()` signature unchanged across Tasks 4/5. ✓
