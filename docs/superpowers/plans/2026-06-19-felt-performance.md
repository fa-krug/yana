# Felt-Performance & Loading-State UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce real loading times where cheap and mask the rest with native-feeling loading states, so the app *feels* faster across launch, reader swiping, feed updates, AI summarize, and search.

**Architecture:** Build three shared primitives first (a skeleton/redaction modifier, a shared cross-fade timing constant, and an observable update-progress tracker), then apply them across each surface. Reader gains a bounded LRU page cache + wide directional prewarm so burst swiping is delay-free. Pure logic (LRU, prewarm window, load-state derivation, progress tracking) is extracted into testable types; UIKit/SwiftUI presentation wiring is verified manually.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, UIKit (`UIPageViewController`), WebKit (`WKWebView`), Swift Testing (`import Testing`).

## Global Constraints

- **Platform:** iOS 26.0+; `@MainActor` throughout; Swift 6 strict concurrency.
- **No third-party dependencies** — native SwiftUI/UIKit/WebKit/SwiftData only.
- **Localization:** every new user-facing string MUST be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state": "translated"`. German uses Apple style (infinitive for actions, no Du/Sie).
- **Build/test command:** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- **Project regen:** new source files require `xcodegen generate` before they compile in Xcode (the project is generated from `project.yml`; files are globbed by directory, so no `project.yml` edit is needed — just regenerate).
- **Tests:** Swift Testing framework, `@MainActor struct`, `@Test func`, `#expect(...)`. Place in `YanaTests/`.

---

## File Structure

**Foundation (new):**
- `Yana/Utilities/CrossFade.swift` — shared fade timing/animation/transition constants.
- `Yana/Models/UpdateProgress.swift` — observable completed/total tracker for feed updates.
- `Yana/Views/Components/SkeletonModifier.swift` — `.skeleton(active:)` redaction+pulse modifier.
- `Yana/Views/Components/SkeletonTimelineView.swift` — launch placeholder timeline.

**Reader logic (new):**
- `Yana/Utilities/LRUCache.swift` — generic bounded LRU cache.
- `Yana/Reader/PrewarmPlan.swift` — pure direction-biased prewarm index computation.

**Launch logic (new):**
- `Yana/Reader/TimelineLoadState.swift` — loading/empty/loaded derivation.

**Modified:**
- `Yana/Reader/ReaderArticleViewController.swift` — page cache, prewarm, memory trim, progress in nav bar.
- `Yana/Reader/ReaderWebViewController.swift` — fade-in on `didFinish`, summary-pending render.
- `Yana/Reader/ReaderHostView.swift` — launch states, thread progress + summarize-pending down.
- `Yana/Reader/ArticleRenderer.swift` — summary-pending placeholder rendering.
- `Yana/Services/AggregationService.swift` — drive `UpdateProgress` from `updateAll()`.
- `Yana/Resources/ArticleRendering/core.css` — `.yana-summary-pending` skeleton CSS.
- `Yana/Views/Config/IdentifierSearchView.swift` — skeleton result rows + cross-fade.
- `Yana/Views/Config/FeedsView.swift` — OPML import progress overlay.
- `Yana/Resources/Localizable.xcstrings` — new strings (+ `de`).

**Tests (new):**
- `YanaTests/CrossFadeTests.swift`, `YanaTests/UpdateProgressTests.swift`,
  `YanaTests/LRUCacheTests.swift`, `YanaTests/PrewarmPlanTests.swift`,
  `YanaTests/TimelineLoadStateTests.swift`, `YanaTests/ArticleRendererPendingSummaryTests.swift`.
- `YanaTests/AggregationServiceTests.swift` — extend with progress assertion.

---

## Task 1: CrossFade timing constants

**Files:**
- Create: `Yana/Utilities/CrossFade.swift`
- Test: `YanaTests/CrossFadeTests.swift`

**Interfaces:**
- Produces: `enum CrossFade { static let duration: TimeInterval; static var animation: Animation; static var transition: AnyTransition }`

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/CrossFadeTests.swift
import Foundation
import Testing
@testable import Yana

struct CrossFadeTests {
    @Test func durationIsTwoTenthsOfASecond() {
        #expect(CrossFade.duration == 0.2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `CrossFade` not found (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Yana/Utilities/CrossFade.swift
import SwiftUI

/// Single source of truth for the loading→loaded fade used across every surface, so the
/// masking feels consistent. Keep it subtle and native — a plain opacity ease, no custom curve.
enum CrossFade {
    /// Fade duration in seconds.
    static let duration: TimeInterval = 0.2
    /// SwiftUI animation for `withAnimation` / `.animation(_:value:)`.
    static var animation: Animation { .easeInOut(duration: duration) }
    /// SwiftUI transition for content that swaps loading→loaded.
    static var transition: AnyTransition { .opacity }
}
```

- [ ] **Step 4: Regenerate project and run test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/CrossFade.swift YanaTests/CrossFadeTests.swift
git commit -m "feat(perf): shared CrossFade timing constants"
```

---

## Task 2: UpdateProgress tracker

**Files:**
- Create: `Yana/Models/UpdateProgress.swift`
- Test: `YanaTests/UpdateProgressTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class UpdateProgress` with
  `var completed: Int` (private(set)), `var total: Int` (private(set)),
  `var isActive: Bool`, `var fraction: Double`,
  `func start(total: Int)`, `func advance()`, `func reset()`.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/UpdateProgressTests.swift
import Foundation
import Testing
@testable import Yana

@MainActor
struct UpdateProgressTests {
    @Test func idleIsInactive() {
        let p = UpdateProgress()
        #expect(p.isActive == false)
        #expect(p.fraction == 0)
    }

    @Test func startSetsTotalAndActivates() {
        let p = UpdateProgress()
        p.start(total: 4)
        #expect(p.isActive)
        #expect(p.total == 4)
        #expect(p.completed == 0)
        #expect(p.fraction == 0)
    }

    @Test func advanceIncrementsAndClampsToTotal() {
        let p = UpdateProgress()
        p.start(total: 2)
        p.advance()
        #expect(p.completed == 1)
        #expect(p.fraction == 0.5)
        p.advance(); p.advance()
        #expect(p.completed == 2) // clamped
        #expect(p.fraction == 1)
    }

    @Test func resetReturnsToIdle() {
        let p = UpdateProgress()
        p.start(total: 3); p.advance()
        p.reset()
        #expect(p.isActive == false)
        #expect(p.total == 0)
        #expect(p.completed == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `UpdateProgress` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
// Yana/Models/UpdateProgress.swift
import Foundation

/// Observable completed/total tracker for a multi-feed update run. Additive telemetry only:
/// the reader reads it to show "Updating N of M…" while feeds upsert incrementally. Single-feed
/// / single-article operations leave it idle (they use the indeterminate spinner instead).
@MainActor
@Observable
final class UpdateProgress {
    private(set) var completed = 0
    private(set) var total = 0

    /// True while a counted multi-feed run is in flight.
    var isActive: Bool { total > 0 }

    /// 0…1 progress; 0 when idle.
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    func start(total: Int) {
        self.total = max(0, total)
        completed = 0
    }

    func advance() {
        guard total > 0 else { return }
        completed = min(completed + 1, total)
    }

    func reset() {
        total = 0
        completed = 0
    }
}
```

- [ ] **Step 4: Regenerate project and run test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/UpdateProgress.swift YanaTests/UpdateProgressTests.swift
git commit -m "feat(perf): UpdateProgress tracker for feed updates"
```

---

## Task 3: Skeleton modifier + skeleton timeline view

**Files:**
- Create: `Yana/Views/Components/SkeletonModifier.swift`
- Create: `Yana/Views/Components/SkeletonTimelineView.swift`

**Interfaces:**
- Produces: `extension View { func skeleton(active: Bool) -> some View }`
- Produces: `struct SkeletonTimelineView: View` (no parameters) — full-screen redacted article placeholder for launch.

**Note on testing:** these are pure SwiftUI presentation views with no branching logic; they have no meaningful unit test. Verification is manual (Step 3). Do not fabricate a placeholder test.

- [ ] **Step 1: Implement the skeleton modifier**

```swift
// Yana/Views/Components/SkeletonModifier.swift
import SwiftUI

/// Native placeholder treatment: system redaction plus a slow, subtle opacity pulse.
/// No custom shimmer gradient — keep it "native & invisible". When `active` is false the
/// content renders normally.
private struct SkeletonModifier: ViewModifier {
    let active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        if active {
            content
                .redacted(reason: .placeholder)
                .opacity(pulse ? 0.45 : 0.85)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
                .accessibilityHidden(true)
        } else {
            content
        }
    }
}

extension View {
    /// Render `self` as a redacted, gently pulsing placeholder while `active`.
    func skeleton(active: Bool) -> some View { modifier(SkeletonModifier(active: active)) }
}
```

- [ ] **Step 2: Implement the skeleton timeline view**

```swift
// Yana/Views/Components/SkeletonTimelineView.swift
import SwiftUI

/// Launch placeholder shown while the timeline is still resolving, so the cold-start frame
/// is a believable article shape instead of a blank or a wrong "No Articles" flash.
struct SkeletonTimelineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(height: 200)                       // lead image
            Text("Placeholder article headline goes here")  // headline
                .font(.title2.bold())
            Text("Feed name")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .skeleton(active: true)
        .background(Color(.systemBackground))
    }
}
```

- [ ] **Step 3: Regenerate, build, and verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds. (Visual verification happens in Task 8 once it is wired into `ReaderScreen`.)

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Components/SkeletonModifier.swift Yana/Views/Components/SkeletonTimelineView.swift
git commit -m "feat(perf): skeleton modifier + launch skeleton timeline"
```

---

## Task 4: Generic LRU cache

**Files:**
- Create: `Yana/Utilities/LRUCache.swift`
- Test: `YanaTests/LRUCacheTests.swift`

**Interfaces:**
- Produces: `final class LRUCache<Key: Hashable, Value>` with
  `init(capacity: Int)`, `func value(for key: Key) -> Value?` (marks MRU),
  `@discardableResult func insert(_ value: Value, for key: Key) -> Value?` (returns evicted value, if any),
  `func removeValue(for key: Key) -> Value?`,
  `func trim(toKeep keys: Set<Key>) -> [Value]` (evict everything except `keys`, returns evicted),
  `var keys: [Key]` (LRU→MRU order), `var count: Int`.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/LRUCacheTests.swift
import Testing
@testable import Yana

struct LRUCacheTests {
    @Test func insertAndRetrieve() {
        let c = LRUCache<String, Int>(capacity: 2)
        c.insert(1, for: "a")
        #expect(c.value(for: "a") == 1)
        #expect(c.value(for: "missing") == nil)
    }

    @Test func evictsLeastRecentlyUsedOverCapacity() {
        let c = LRUCache<String, Int>(capacity: 2)
        c.insert(1, for: "a")
        c.insert(2, for: "b")
        let evicted = c.insert(3, for: "c")  // capacity 2 → "a" evicted
        #expect(evicted == 1)
        #expect(c.value(for: "a") == nil)
        #expect(c.value(for: "b") == 2)
        #expect(c.value(for: "c") == 3)
    }

    @Test func accessPromotesToMostRecentlyUsed() {
        let c = LRUCache<String, Int>(capacity: 2)
        c.insert(1, for: "a")
        c.insert(2, for: "b")
        _ = c.value(for: "a")               // "a" now MRU, "b" is LRU
        c.insert(3, for: "c")               // evicts "b"
        #expect(c.value(for: "b") == nil)
        #expect(c.value(for: "a") == 1)
    }

    @Test func trimEvictsEverythingNotKept() {
        let c = LRUCache<String, Int>(capacity: 5)
        c.insert(1, for: "a"); c.insert(2, for: "b"); c.insert(3, for: "c")
        let evicted = c.trim(toKeep: ["b"]).sorted()
        #expect(evicted == [1, 3])
        #expect(c.value(for: "b") == 2)
        #expect(c.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `LRUCache` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
// Yana/Utilities/LRUCache.swift
import Foundation

/// A simple bounded least-recently-used cache. `order` holds keys from LRU (first) to MRU (last);
/// `store` holds the values. Used by the reader to keep recently-seen page controllers warm while
/// capping how many live `WKWebView`s exist at once.
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var store: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { store.count }
    var keys: [Key] { order }

    /// Returns the value and promotes the key to most-recently-used.
    func value(for key: Key) -> Value? {
        guard let value = store[key] else { return nil }
        promote(key)
        return value
    }

    /// Inserts/updates a value as most-recently-used. Returns an evicted value if capacity was hit.
    @discardableResult
    func insert(_ value: Value, for key: Key) -> Value? {
        store[key] = value
        promote(key)
        guard store.count > capacity, let lru = order.first else { return nil }
        order.removeFirst()
        return store.removeValue(forKey: lru)
    }

    @discardableResult
    func removeValue(for key: Key) -> Value? {
        order.removeAll { $0 == key }
        return store.removeValue(forKey: key)
    }

    /// Evicts every entry whose key is not in `keys`. Returns the evicted values.
    func trim(toKeep keys: Set<Key>) -> [Value] {
        let drop = order.filter { !keys.contains($0) }
        order.removeAll { !keys.contains($0) }
        return drop.compactMap { store.removeValue(forKey: $0) }
    }

    private func promote(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
```

- [ ] **Step 4: Regenerate project and run test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/LRUCache.swift YanaTests/LRUCacheTests.swift
git commit -m "feat(perf): generic bounded LRU cache"
```

---

## Task 5: Prewarm plan (direction-biased window)

**Files:**
- Create: `Yana/Reader/PrewarmPlan.swift`
- Test: `YanaTests/PrewarmPlanTests.swift`

**Interfaces:**
- Produces: `enum PrewarmPlan` with `enum Direction { case forward, backward, none }` and
  `static func indices(current: Int, count: Int, radius: Int, direction: Direction) -> [Int]`.
- Returns valid in-bounds indices to prewarm, excluding `current`, ordered so the bias
  direction's neighbors come first. Radius applies on both sides; the bias only reorders.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/PrewarmPlanTests.swift
import Testing
@testable import Yana

struct PrewarmPlanTests {
    @Test func forwardBiasOrdersAheadFirst() {
        let r = PrewarmPlan.indices(current: 5, count: 20, radius: 2, direction: .forward)
        #expect(r == [6, 7, 4, 3])
    }

    @Test func backwardBiasOrdersBehindFirst() {
        let r = PrewarmPlan.indices(current: 5, count: 20, radius: 2, direction: .backward)
        #expect(r == [4, 3, 6, 7])
    }

    @Test func clampsToBounds() {
        let r = PrewarmPlan.indices(current: 1, count: 4, radius: 3, direction: .forward)
        // ahead: 2,3 (4+ out of range); behind: 0
        #expect(r == [2, 3, 0])
    }

    @Test func excludesCurrentAndHandlesEmpty() {
        #expect(PrewarmPlan.indices(current: 0, count: 0, radius: 5, direction: .forward).isEmpty)
        #expect(PrewarmPlan.indices(current: 0, count: 1, radius: 5, direction: .forward).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `PrewarmPlan` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
// Yana/Reader/PrewarmPlan.swift
import Foundation

/// Pure computation of which neighbor indices to prewarm around the current page, biased toward
/// the swipe direction so a one-direction burst warms first. Keeps the reader VC's prewarm logic
/// testable without a live UIPageViewController.
enum PrewarmPlan {
    enum Direction { case forward, backward, none }

    static func indices(current: Int, count: Int, radius: Int, direction: Direction) -> [Int] {
        guard count > 1, radius > 0, current >= 0, current < count else { return [] }
        let ahead = (1...radius).map { current + $0 }.filter { $0 < count }
        let behind = (1...radius).map { current - $0 }.filter { $0 >= 0 }
        switch direction {
        case .forward:  return ahead + behind
        case .backward: return behind + ahead
        case .none:
            // Interleave nearest-first when there is no travel direction.
            var result: [Int] = []
            for i in 0..<radius {
                if i < ahead.count { result.append(ahead[i]) }
                if i < behind.count { result.append(behind[i]) }
            }
            return result
        }
    }
}
```

- [ ] **Step 4: Regenerate project and run test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/PrewarmPlan.swift YanaTests/PrewarmPlanTests.swift
git commit -m "feat(reader): direction-biased prewarm plan"
```

---

## Task 6: Reader page cache + wide prewarm + memory trim

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift`

**Interfaces:**
- Consumes: `LRUCache<String, ReaderWebViewController>` (Task 4), `PrewarmPlan` (Task 5).
- Behavior change only — no new public API. `makePage(for:)` becomes cache-backed; prewarm runs
  on settle; memory warnings trim to the live window.

**Note on testing:** the cache/prewarm *logic* is unit-tested in Tasks 4–5. This task is UIKit
wiring; verify manually (Step 6). Do not add a placeholder unit test for the view controller.

- [ ] **Step 1: Add cache, constants, and direction state**

In `ReaderArticleViewController`, add stored properties near the existing `private var articles`:

```swift
    /// Reader prewarm/cache tuning. Constants so they can be profiled and dialed on-device.
    /// Radius covers a 5-swipe burst in one direction; capacity holds ±radius on both sides
    /// plus a little recent history, bounding live WKWebViews.
    private static let prewarmRadius = 5
    private static let pageCacheCapacity = 25

    /// Reused page controllers keyed by article identifier; revisiting a recent article is then
    /// instant (no re-render). LRU eviction tears down off-window web views to bound memory.
    private let pageCache = LRUCache<String, ReaderWebViewController>(capacity: pageCacheCapacity)

    /// Last observed travel direction, used to bias prewarming toward where the user is going.
    private var lastDirection: PrewarmPlan.Direction = .none
```

- [ ] **Step 2: Make `makePage(for:)` cache-backed**

Replace the existing `makePage(for:)` with:

```swift
    private func makePage(for index: Int) -> ReaderWebViewController? {
        guard articles.indices.contains(index) else { return nil }
        let article = articles[index]
        if let cached = pageCache.value(for: article.identifier) { return cached }
        let vc = ReaderWebViewController(
            article: article,
            allowsFullscreen: isFullscreenAvailable,
            onRefresh: onRefresh,
            onRequestShowBars: { [weak self] in self?.applyFullscreen(false, animated: true) }
        )
        vc.hideBarsTapZonesActive(settings.articleFullscreenEnabled && isFullscreenAvailable)
        pageCache.insert(vc, for: article.identifier)
        return vc
    }

    /// Instantiate (and thus begin loading) the neighbors around `index`, biased toward the last
    /// travel direction, so a burst of swipes lands on already-rendered HTML.
    private func prewarmNeighbors(around index: Int) {
        let targets = PrewarmPlan.indices(
            current: index, count: articles.count,
            radius: Self.prewarmRadius, direction: lastDirection
        )
        for i in targets {
            let vc = makePage(for: i)         // inserts into cache + triggers loadHTMLString
            vc?.loadViewIfNeeded()            // force viewDidLoad → render() now, off-screen
        }
    }
```

- [ ] **Step 3: Track direction and prewarm on transition start + settle**

In `pageViewController(_:willTransitionTo:)`, set the direction before the existing `isTransitioning = true`:

```swift
    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        if let next = pendingViewControllers.first as? ReaderWebViewController,
           let target = TimelinePageIndex.index(of: next.article.identifier, in: articles) {
            lastDirection = target > index ? .forward : .backward
            prewarmNeighbors(around: target)   // warm mid-swipe, not only after it finishes
        }
        isTransitioning = true
    }
```

In `pageViewController(_:didFinishAnimating:previousViewControllers:transitionCompleted:)`, after the existing `onIndexChange?(i)` call, add:

```swift
        prewarmNeighbors(around: i)
```

- [ ] **Step 4: Prewarm on initial configure**

At the end of `configure(articles:index:)`, after `updateStarItem()`, add:

```swift
        prewarmNeighbors(around: self.index)
```

- [ ] **Step 5: Trim cache on memory pressure**

Add a memory-warning observer. In `viewDidLoad()`, after `pageController.didMove(toParent: self)`:

```swift
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
```

Add the handler and a `deinit` (the class has none yet):

```swift
    @objc private func handleMemoryWarning() {
        // Keep only the live ±1 window so the current page and its immediate neighbors survive.
        let live = PrewarmPlan.indices(current: index, count: articles.count, radius: 1, direction: .none) + [index]
        let keep = Set(live.filter { articles.indices.contains($0) }.map { articles[$0].identifier })
        _ = pageCache.trim(toKeep: keep)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
```

- [ ] **Step 6: Regenerate, build, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds.

Manual: launch app, swipe forward through ~6 articles quickly — pages should appear without a blank/re-render delay; swipe back through them — instant (cached). In Xcode, Debug ▸ Simulate Memory Warning — app stays responsive, no crash.

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift
git commit -m "feat(reader): cache page controllers + wide directional prewarm with memory trim"
```

---

## Task 7: Reader fade-in on actual load completion

**Files:**
- Modify: `Yana/Reader/ReaderWebViewController.swift`

**Interfaces:**
- Consumes: `CrossFade` (Task 1).
- Behavior change only: the web view starts hidden over a `.systemBackground` container and
  cross-fades in when `WKNavigationDelegate.didFinish` fires, removing the white/previous-article
  flash. No themed-CSS color parsing — `.systemBackground` already adapts light/dark.

**Note on testing:** presentation behavior; verify manually (Step 4).

- [ ] **Step 1: Start the web view hidden over the system background**

In `viewDidLoad()`, after `webView = WKWebView(frame: view.bounds, configuration: config)` and before adding subviews, add:

```swift
        // Avoid the white/system flash and the lingering previous article: the container shows a
        // system background (adapts light/dark) while the web view paints, then we fade it in.
        view.backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.alpha = 0
```

- [ ] **Step 2: Reset alpha on every (re-)render so reused pages fade too**

In `render()`, right after the `guard html != loadedHTML else { return }` line, add:

```swift
        webView.alpha = 0
```

- [ ] **Step 3: Fade in on didFinish**

Add the navigation-delegate method (the class already conforms to `WKNavigationDelegate`):

```swift
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.alpha < 1 else { return }
        UIView.animate(withDuration: CrossFade.duration) { webView.alpha = 1 }
    }
```

- [ ] **Step 4: Regenerate, build, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds.

Manual: with a dark reader theme selected, swipe between articles — no white flash; the new article fades in over the system background rather than popping.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderWebViewController.swift
git commit -m "feat(reader): fade article in on load completion, no flash"
```

---

## Task 8: Launch load-state (kill the empty-state flash)

**Files:**
- Create: `Yana/Reader/TimelineLoadState.swift`
- Test: `YanaTests/TimelineLoadStateTests.swift`
- Modify: `Yana/Reader/ReaderHostView.swift`

**Interfaces:**
- Produces: `enum TimelineLoadState { case loading, empty, loaded; static func derive(hasComputedFilter: Bool, count: Int) -> TimelineLoadState }`
- Consumes: `SkeletonTimelineView` (Task 3).

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/TimelineLoadStateTests.swift
import Testing
@testable import Yana

struct TimelineLoadStateTests {
    @Test func loadingUntilFilterComputed() {
        #expect(TimelineLoadState.derive(hasComputedFilter: false, count: 0) == .loading)
        #expect(TimelineLoadState.derive(hasComputedFilter: false, count: 10) == .loading)
    }

    @Test func emptyOnlyWhenConfirmedZero() {
        #expect(TimelineLoadState.derive(hasComputedFilter: true, count: 0) == .empty)
    }

    @Test func loadedWhenArticlesPresent() {
        #expect(TimelineLoadState.derive(hasComputedFilter: true, count: 3) == .loaded)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `TimelineLoadState` not found.

- [ ] **Step 3: Implement the state derivation**

```swift
// Yana/Reader/TimelineLoadState.swift
import Foundation

/// Distinguishes "timeline not yet computed" from "genuinely empty" so the cold-start frame
/// shows a skeleton, not a wrong "No Articles" flash. `hasComputedFilter` becomes true after the
/// first `recomputeFilter()` run in `ReaderScreen`.
enum TimelineLoadState: Equatable {
    case loading
    case empty
    case loaded

    static func derive(hasComputedFilter: Bool, count: Int) -> TimelineLoadState {
        guard hasComputedFilter else { return .loading }
        return count == 0 ? .empty : .loaded
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Wire into `ReaderScreen`**

In `ReaderScreen`, add a flag near the other `@State` declarations:

```swift
    @State private var hasComputedFilter = false
```

At the end of `recomputeFilter()`, after `filteredArticles = ...`, add:

```swift
        hasComputedFilter = true
```

Replace the `if articles.isEmpty { ... } else { ReaderHostView(... ) }` branch in `body` with a switch on the derived state:

```swift
        let articles = filteredArticles
        Group {
            switch TimelineLoadState.derive(hasComputedFilter: hasComputedFilter, count: articles.count) {
            case .loading:
                SkeletonTimelineView()
            case .empty:
                ContentUnavailableView {
                    Label("No Articles", systemImage: "tray")
                        .accessibilityIdentifier("emptyArticlesTitle")
                } description: {
                    Text("Add feeds in Settings, then pull down to refresh.")
                } actions: {
                    Button(String(localized: "Add Your First Feed")) { appState.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded:
                ReaderHostView(
                    articles: articles,
                    currentIndex: $appState.currentIndex,
                    isRefreshing: UpdateActivity.shared.isUpdating || isSummarizing,
                    isFilterActive: settings.isTimelineFilterActive,
                    onRefresh: triggerRefresh,
                    onShowFilter: { appState.showFilter = true },
                    onShowArticleList: { appState.showArticleList = true },
                    onShowSettings: { appState.showSettings = true },
                    onToggleStar: toggleStar,
                    onForceUpdateArticle: forceUpdateArticle,
                    onCopyLink: copyLink,
                    onSummarize: summarize,
                    aiReady: aiReady,
                    isSummarizing: isSummarizing,
                    reloadToken: reloadToken
                )
                .ignoresSafeArea()
            }
        }
```

(The `.sheet`/`.alert`/`.overlay`/`.onAppear`/`.onChange` modifiers stay attached to the `Group` exactly as before.)

- [ ] **Step 6: Regenerate, build, run full test suite, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

Manual: cold-launch with a populated library — the skeleton timeline shows briefly, then the reader; the "No Articles" view no longer flashes. With an empty library — skeleton briefly, then "No Articles".

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/TimelineLoadState.swift YanaTests/TimelineLoadStateTests.swift Yana/Reader/ReaderHostView.swift
git commit -m "feat(launch): skeleton timeline + confirmed-empty gating, no empty-state flash"
```

---

## Task 9: AggregationService drives UpdateProgress

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Test: `YanaTests/AggregationServiceTests.swift` (extend)

**Interfaces:**
- Consumes: `UpdateProgress` (Task 2).
- Produces: `let updateProgress = UpdateProgress()` on `AggregationService` (public read access);
  `updateAll()` calls `updateProgress.start(total:)` before the loop, `updateProgress.advance()`
  as each feed finishes, and `updateProgress.reset()` in `defer`.

- [ ] **Step 1: Write the failing test**

First **read `YanaTests/AggregationServiceTests.swift`** and reuse its existing in-memory
`ModelContainer` setup, feed-seeding helper, and aggregator stub (the suite already constructs an
`AggregationService` with a mock `makeAggregator`). Match those helpers' exact names — do not
introduce a new stub type. Add a test that (a) captures `total` mid-run from inside the stub's
`aggregate()` (which runs on the main actor during the loop) and (b) asserts progress resets to
idle after the run. Shape:

```swift
    @Test func updateAllReportsProgressThenResets() async throws {
        // Reuse the suite's helpers: an in-memory context + 3 enabled feeds.
        let context = try makeInMemoryContext()        // ← existing helper name; adapt to the suite
        seedEnabledFeeds(count: 3, in: context)         // ← existing helper name; adapt to the suite

        var totalSeenDuringRun = 0
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                // Capture the live total while a feed is being aggregated (mid-run, on main actor).
                StubAggregator { totalSeenDuringRun = service.updateProgress.total }
            }
        )
        await service.updateAll()

        #expect(totalSeenDuringRun == 3)                 // total was live during the run
        #expect(service.updateProgress.total == 0)       // reset to idle afterward
        #expect(service.updateProgress.completed == 0)
    }
```

> Implementer note: the `service` capture inside the factory closure is intentional — the closure
> is invoked during `updateAll()`, after `service` is assigned, so the reference is valid. If the
> suite's stub takes no `onAggregate` hook, add a minimal hook to the existing stub (or use whatever
> per-feed callback it already exposes) rather than inventing a parallel stub type. The deterministic,
> must-pass assertions are the two post-run `== 0` checks; the `totalSeenDuringRun == 3` check
> proves the counter was live and should hold given the mock runs synchronously enough to observe it.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `service.updateProgress` does not exist (compile error).

- [ ] **Step 3: Add the tracker and drive it from `updateAll()`**

Add the property near `var isUpdating = false`:

```swift
    /// Counted progress for the most recent `updateAll()` run; idle otherwise. Read by the reader
    /// to show "Updating N of M…". Single-feed/article operations leave it idle.
    let updateProgress = UpdateProgress()
```

In `updateAll()`, set the total before the task group and reset on exit. Change the top of the method:

```swift
    func updateAll() async -> Int {
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false; updateProgress.reset() }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = ((try? context.fetch(descriptor)) ?? [])
            .filter { settings.isSourceEnabled($0.type) }

        let ids = feeds.map(\.persistentModelID)
        updateProgress.start(total: ids.count)
        var inserted = 0
```

In the `while let result = await group.next()` loop, add `updateProgress.advance()` as the first line of the loop body (each completed feed):

```swift
            while let result = await group.next() {
                updateProgress.advance()
                inserted += result
                if Task.isCancelled { break }
                if nextIndex < ids.count {
                    let id = ids[nextIndex]
                    group.addTask { await self.aggregate(feedID: id) }
                    nextIndex += 1
                }
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat(perf): report per-feed update progress from updateAll"
```

---

## Task 10: Show update progress in the reader nav bar

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift`
- Modify: `Yana/Reader/ReaderHostView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AggregationService.updateProgress` (Task 9) surfaced as an optional
  `(completed: Int, total: Int)` passed into the reader.
- Produces: `ReaderArticleViewController.setUpdateProgress(_ progress: (completed: Int, total: Int)?)`
  — when non-nil and total > 1, shows "Updating N of M…" beside the spinner; otherwise the
  existing indeterminate spinner only.

- [ ] **Step 1: Add a progress label to the reader chrome**

In `ReaderArticleViewController`, add a label and bar-button item near `activityIndicator`:

```swift
    private let progressLabel = UILabel()
    private var progressItem: UIBarButtonItem!
```

In `configureNavigationItems()`, after `indicatorItem = UIBarButtonItem(customView: activityIndicator)`:

```swift
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = .secondaryLabel
        progressItem = UIBarButtonItem(customView: progressLabel)
```

Add the setter:

```swift
    /// Show "Updating N of M…" during a counted multi-feed run; pass nil to clear. The indeterminate
    /// spinner (setRefreshing) still drives the activity indicator itself.
    func setUpdateProgress(_ progress: (completed: Int, total: Int)?) {
        guard let progress, progress.total > 1 else {
            if navigationItem.leftBarButtonItems?.contains(progressItem) == true {
                setRefreshing(activityIndicator.isAnimating) // rebuild left items without progress
            }
            return
        }
        progressLabel.text = String(localized: "Updating \(progress.completed) of \(progress.total)…")
        progressLabel.sizeToFit()
        let items: [UIBarButtonItem] = [articleListItem, indicatorItem, progressItem]
        if navigationItem.leftBarButtonItems != items {
            navigationItem.leftBarButtonItems = items
        }
    }
```

> Note: `setRefreshing` already manages the left items. Keep `setRefreshing` authoritative for the
> spinner; `setUpdateProgress` only adds/removes the trailing label. When progress is non-nil,
> `setUpdateProgress` sets the full `[articleListItem, indicatorItem, progressItem]`; when nil it
> defers to `setRefreshing`'s `[articleListItem, indicatorItem]` / `[articleListItem]`.

- [ ] **Step 2: Thread progress through `ReaderHostView`**

Add an input to `ReaderHostView`:

```swift
    let updateProgress: (completed: Int, total: Int)?
```

In both `makeUIViewController` and `updateUIViewController`, after `reader.setRefreshing(isRefreshing)`:

```swift
        reader.setUpdateProgress(updateProgress)
```

- [ ] **Step 3: Supply progress from `ReaderScreen`**

`ReaderScreen` creates a fresh `AggregationService` per refresh, so expose progress through a
shared instance. Add a `@State` service-progress mirror updated by the refresh task. Simplest:
add a `@State private var updateProgress: (completed: Int, total: Int)? = nil` and have the refresh
task poll the service's `updateProgress` while running. Replace `triggerRefresh()` body:

```swift
    private func triggerRefresh() {
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    updateProgress = service.updateProgress.isActive
                        ? (service.updateProgress.completed, service.updateProgress.total) : nil
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let count = await service.updateAll()
            monitor.cancel()
            updateProgress = nil
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: nil)
                Haptics.impact(.light)
            }
        }
    }
```

Pass it into the `ReaderHostView(...)` call (Task 8's `.loaded` branch) by adding the argument:

```swift
                    reloadToken: reloadToken,
                    updateProgress: updateProgress
```

(Add `updateProgress: nil` is not needed — the binding always supplies the current value.)

- [ ] **Step 4: Add the localized string**

In `Yana/Resources/Localizable.xcstrings`, add a `"Updating %lld of %lld…"` key. The Swift
interpolation `String(localized: "Updating \(a) of \(b)…")` produces the key
`"Updating %lld of %lld…"`. Add this entry to the catalog's `strings` object:

```json
"Updating %lld of %lld…" : {
  "extractionState" : "manual",
  "localizations" : {
    "de" : {
      "stringUnit" : { "state" : "translated", "value" : "%1$lld von %2$lld werden aktualisiert …" }
    }
  }
}
```

- [ ] **Step 5: Regenerate, build, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds.

Manual: with several feeds, pull to refresh — the nav bar shows "Updating N of M…" with the count climbing while new articles appear in the timeline; the label clears on completion. Switch device language to German — label reads "N von M werden aktualisiert …".

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift Yana/Reader/ReaderHostView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(perf): show 'Updating N of M' progress during feed updates"
```

---

## Task 11: ArticleRenderer summary-pending placeholder

**Files:**
- Modify: `Yana/Reader/ArticleRenderer.swift`
- Modify: `Yana/Resources/ArticleRendering/core.css`
- Test: `YanaTests/ArticleRendererPendingSummaryTests.swift`

**Interfaces:**
- Produces: `ArticleRenderer.composeBody(content:summary:summaryPending:)` with
  `summaryPending: Bool = false`. When `summaryPending` is true and `summary` is empty, a
  placeholder block (`class="yana-summary yana-summary-pending"`) is inserted at the same spot a
  real summary would go. A present summary always wins over pending.
- Produces: `articleHTML(...)` and `fullPageHTML(...)` gain a `summaryPending: Bool = false`
  parameter threaded into `composeBody`.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/ArticleRendererPendingSummaryTests.swift
import Foundation
import Testing
@testable import Yana

@MainActor
struct ArticleRendererPendingSummaryTests {
    @Test func pendingInsertsPlaceholderWhenNoSummaryYet() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "", summaryPending: true)
        #expect(html.contains("yana-summary-pending"))
        let placeholderRange = html.range(of: "yana-summary-pending")
        let bodyRange = html.range(of: "<p>body</p>")
        #expect(placeholderRange != nil && bodyRange != nil)
        #expect(placeholderRange!.lowerBound < bodyRange!.lowerBound)
    }

    @Test func realSummaryWinsOverPending() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "real", summaryPending: true)
        #expect(html.contains("real"))
        #expect(!html.contains("yana-summary-pending"))
    }

    @Test func notPendingAndNoSummaryIsContentOnly() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "", summaryPending: false)
        #expect(html == "<p>body</p>")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `composeBody` has no `summaryPending` parameter.

- [ ] **Step 3: Implement pending rendering**

Replace `composeBody` and thread the flag through. New `composeBody`:

```swift
    static func composeBody(content: String, summary: String, summaryPending: Bool = false) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let label = ContentFormatter.escapeHTML(String(localized: "Summary"))
            let escaped = ContentFormatter.escapeHTML(trimmed)
            let block = "<div class=\"yana-summary\"><div class=\"yana-summary-label\">\(label)</div>\(escaped)</div>"
            return insert(summaryBlock: block, into: content)
        }
        guard summaryPending else { return content }
        let label = ContentFormatter.escapeHTML(String(localized: "Summary"))
        // Skeleton lines mask the wait at the exact spot the real summary will land.
        let block = "<div class=\"yana-summary yana-summary-pending\">"
            + "<div class=\"yana-summary-label\">\(label)</div>"
            + "<div class=\"yana-skel-line\"></div><div class=\"yana-skel-line\"></div>"
            + "<div class=\"yana-skel-line short\"></div></div>"
        return insert(summaryBlock: block, into: content)
    }
```

Update `articleSubstitutions` to pass the flag, and add the parameter to `articleHTML` / `fullPageHTML`:

```swift
    static func articleHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize,
                            summaryPending: Bool = false) -> Rendering {
        // ...unchanged until the body substitution; pass summaryPending into articleSubstitutions...
    }

    static func fullPageHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize,
                             summaryPending: Bool = false) -> String {
        let rendering = articleHTML(article: article, theme: theme, textSize: textSize, summaryPending: summaryPending)
        // ...unchanged...
    }
```

In `articleSubstitutions`, change the signature to accept `summaryPending: Bool` and update the body line:

```swift
        d["body"] = Self.composeBody(content: article.content, summary: article.summary, summaryPending: summaryPending)
```

(Thread `summaryPending` from `articleHTML` → `articleSubstitutions`.)

- [ ] **Step 4: Add skeleton CSS to core.css**

Append to `Yana/Resources/ArticleRendering/core.css`:

```css
/* Pending-summary skeleton: subtle pulsing lines while an on-demand summary is generated. */
.yana-summary-pending .yana-skel-line {
  height: 0.9em;
  margin: 0.5em 0;
  border-radius: 4px;
  background: currentColor;
  opacity: 0.12;
  animation: yana-skel-pulse 1.2s ease-in-out infinite;
}
.yana-summary-pending .yana-skel-line.short { width: 60%; }
@keyframes yana-skel-pulse {
  0%, 100% { opacity: 0.08; }
  50%      { opacity: 0.20; }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/ArticleRenderer.swift Yana/Resources/ArticleRendering/core.css YanaTests/ArticleRendererPendingSummaryTests.swift
git commit -m "feat(reader): pending-summary skeleton placeholder rendering"
```

---

## Task 12: Wire summarize placeholder through the reader

**Files:**
- Modify: `Yana/Reader/ReaderWebViewController.swift`
- Modify: `Yana/Reader/ReaderArticleViewController.swift`
- Modify: `Yana/Reader/ReaderHostView.swift`

**Interfaces:**
- Consumes: `ArticleRenderer.fullPageHTML(..., summaryPending:)` (Task 11).
- Produces: `ReaderWebViewController.summaryPending: Bool` (re-renders on change);
  `ReaderArticleViewController.setSummarizing(_ summarizing: Bool)` — sets `summaryPending` on the
  currently displayed page only.

**Note on testing:** the placeholder HTML is unit-tested in Task 11; this is wiring. Verify manually.

- [ ] **Step 1: Add `summaryPending` to `ReaderWebViewController`**

Add the property and pass it into the renderer. Near `private var loadedHTML: String?`:

```swift
    var summaryPending = false { didSet { if summaryPending != oldValue { render() } } }
```

In `render()`, pass it to the renderer:

```swift
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize,
            summaryPending: summaryPending
        )
```

- [ ] **Step 2: Add `setSummarizing` to `ReaderArticleViewController`**

```swift
    /// Toggle the pending-summary placeholder on the visible page (the only one being summarized).
    func setSummarizing(_ summarizing: Bool) {
        displayedWebVC?.summaryPending = summarizing
    }
```

- [ ] **Step 3: Drive it from `ReaderHostView`**

In `updateUIViewController(_:context:)`, after `reader.isSummarizing = isSummarizing`, add:

```swift
        reader.setSummarizing(isSummarizing)
```

(`reloadToken` already triggers `reloadCurrentPage()` when the real summary arrives, which clears
the placeholder because `summary` is now non-empty and wins over pending. Setting
`isSummarizing = false` afterwards also re-renders without the placeholder — the `didSet` guard
prevents a redundant double render.)

- [ ] **Step 4: Regenerate, build, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds.

Manual (requires a configured AI provider): open an article, tap Summarize — pulsing skeleton lines appear between the lead image and body, then the real summary replaces them when generation finishes. On failure, the placeholder clears and the "Summarize Failed" alert shows.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderWebViewController.swift Yana/Reader/ReaderArticleViewController.swift Yana/Reader/ReaderHostView.swift
git commit -m "feat(reader): show pending-summary skeleton while summarizing"
```

---

## Task 13: Skeleton rows in identifier search

**Files:**
- Modify: `Yana/Views/Config/IdentifierSearchView.swift`

**Interfaces:**
- Consumes: `.skeleton(active:)` (Task 3), `CrossFade` (Task 1).
- Behavior change: while searching with no results yet, show skeleton rows instead of a bare
  `ProgressView`; results cross-fade in. (Debounce already exists — unchanged.)

**Note on testing:** presentation; verify manually.

- [ ] **Step 1: Replace the searching overlay with skeleton rows**

In `IdentifierSearchView.body`, replace the `if model.isSearching && model.rows.isEmpty { ProgressView() }`
branch inside `.overlay { ... }` with skeleton rows:

```swift
            .overlay {
                if model.isSearching && model.rows.isEmpty {
                    List(0..<8, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("r/placeholdername").font(.headline)
                            Text("Placeholder subtitle · 12K subscribers")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                    .skeleton(active: true)
                } else if model.rows.isEmpty {
                    // ...existing ContentUnavailableView branches unchanged...
                }
            }
```

- [ ] **Step 2: Cross-fade results in**

Add an animation to the results list. On the `List(model.rows)` add:

```swift
            .animation(CrossFade.animation, value: model.rows.map(\.id))
```

- [ ] **Step 3: Regenerate, build, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds.

Manual (requires Reddit/YouTube key): open feed creation → identifier search, type a query — skeleton rows pulse while the request is in flight, then real results fade in.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/IdentifierSearchView.swift
git commit -m "feat(search): skeleton result rows + cross-fade while searching"
```

---

## Task 14: OPML import progress overlay

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `CrossFade` (Task 1) for the overlay transition.
- Behavior change: show an "Importing feeds…" overlay while a (possibly large) OPML file is
  parsed/imported, so the operation isn't a silent freeze followed by an alert.

**Note on testing:** the import itself is covered by `FeedPortability` tests; this is presentation.
Verify manually.

- [ ] **Step 1: Add an importing flag and defer the parse one runloop**

In `FeedsView`, add:

```swift
    @State private var isImportingOPML = false
```

Replace `handleImport(_:)` so the overlay can paint before the synchronous parse runs:

```swift
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        isImportingOPML = true
        // Let SwiftUI paint the overlay before the synchronous parse blocks the main actor.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            defer { isImportingOPML = false }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                importMessage = String(localized: "Could not read the file.")
                return
            }
            let r = FeedPortability.importOPML(xml, context: modelContext)
            importMessage = String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped).")
        }
    }
```

- [ ] **Step 2: Add the overlay**

Attach an overlay to the `ManagedList(...)` (alongside the existing modifiers in `body`):

```swift
        .overlay {
            if isImportingOPML {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Importing feeds…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(CrossFade.transition)
            }
        }
        .animation(CrossFade.animation, value: isImportingOPML)
```

- [ ] **Step 3: Add the localized string**

In `Yana/Resources/Localizable.xcstrings`, add:

```json
"Importing feeds…" : {
  "extractionState" : "manual",
  "localizations" : {
    "de" : {
      "stringUnit" : { "state" : "translated", "value" : "Feeds werden importiert …" }
    }
  }
}
```

- [ ] **Step 4: Regenerate, build, verify manually**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds.

Manual: Feeds screen → import a large OPML file — the "Importing feeds…" overlay appears, then the result alert. German language → "Feeds werden importiert …".

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(opml): show progress overlay during import"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests PASS.

- [ ] **Run the docs-update skill before final commit** if any architecture description in
  `CLAUDE.md` needs to reflect the new reader caching / progress behavior.

- [ ] **Manual smoke pass:** cold launch (skeleton, no empty flash) → pull-to-refresh (progress
  count + live articles) → burst-swipe forward/back (no delay, no flash) → summarize (skeleton →
  summary) → identifier search (skeleton rows) → OPML import (overlay).
