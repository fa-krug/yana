# Anchor WebKit Warmup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pre-render the saved anchor article into an off-screen `WKWebView` during launch so the dominant first-paint cost (Web Content process spawn + first-document parse + paint) happens before the reader's first page is created.

**Architecture:** A shared `WKWebViewConfiguration` factory (`ReaderWebView`) owns the reader's shared process pool and image scheme handler. At launch, `ReaderWarmup.start()` resolves the anchor `Article`, renders its HTML, builds a web view through the factory, parents it off-screen in the key window (so WebKit lays out + composites), and parks it in a single-slot `ReaderWarmupStore`. The first `ReaderWebViewController` adopts the warmed view when its rendered HTML matches; otherwise it falls back to building a fresh one. Match validity is gated on exact HTML-string equality, so theme/text-size/summary differences are clean misses.

**Tech Stack:** Swift 6, SwiftUI, UIKit, WebKit, SwiftData, Swift Testing.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` on UI/WebKit/SwiftData-main types.
- Platform: iOS 26.0+.
- Unit tests use Swift Testing (`import Testing`), `@MainActor`; in-memory `ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations:)` with `isStoredInMemoryOnly: true` (mirror existing test files).
- No user-facing strings are added → no `Localizable.xcstrings` changes.
- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- Single test target run: append `-only-testing:YanaTests/ReaderWarmupTests`
- After creating a new `.swift` file, run `xcodegen generate` before building (the project is generated from `project.yml`; new files must be picked up).

---

### Task 1: Warmup slot value type + box (pure logic, fully tested)

**Files:**
- Create: `Yana/Reader/WarmupSlot.swift`
- Test: `YanaTests/ReaderWarmupTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct WarmupSlot<Payload> { let identifier: String; let html: String; let payload: Payload; func matched(identifier: String, html: String) -> Payload? }`
  - `@MainActor final class WarmupSlotBox<Payload> { func store(identifier: String, html: String, payload: Payload); func take(identifier: String, html: String) -> Payload?; func discardUnused() -> Payload? }`

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/ReaderWarmupTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct ReaderWarmupTests {

    @Test func slotMatchesOnIdentifierAndHTML() {
        let slot = WarmupSlot(identifier: "a", html: "<p>x</p>", payload: 42)
        #expect(slot.matched(identifier: "a", html: "<p>x</p>") == 42)
    }

    @Test func slotMissesOnIdentifier() {
        let slot = WarmupSlot(identifier: "a", html: "<p>x</p>", payload: 42)
        #expect(slot.matched(identifier: "b", html: "<p>x</p>") == nil)
    }

    @Test func slotMissesOnHTML() {
        let slot = WarmupSlot(identifier: "a", html: "<p>x</p>", payload: 42)
        #expect(slot.matched(identifier: "a", html: "<p>y</p>") == nil)
    }

    @Test func boxTakeReturnsPayloadOnceThenClears() {
        let box = WarmupSlotBox<String>()
        box.store(identifier: "a", html: "h", payload: "view")
        #expect(box.take(identifier: "a", html: "h") == "view")
        #expect(box.take(identifier: "a", html: "h") == nil)   // single-use: cleared after hit
    }

    @Test func boxTakeOnMissRetainsSlot() {
        let box = WarmupSlotBox<String>()
        box.store(identifier: "a", html: "h", payload: "view")
        #expect(box.take(identifier: "b", html: "h") == nil)   // miss
        #expect(box.discardUnused() == "view")                 // slot survived the miss
    }

    @Test func discardUnusedReturnsAndClears() {
        let box = WarmupSlotBox<String>()
        box.store(identifier: "a", html: "h", payload: "view")
        #expect(box.discardUnused() == "view")
        #expect(box.discardUnused() == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: FAIL — `cannot find 'WarmupSlot' / 'WarmupSlotBox' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Yana/Reader/WarmupSlot.swift`:

```swift
import Foundation

/// One parked warmup payload, keyed by the article identifier and the exact rendered HTML.
/// HTML-string equality is the validity gate: any theme / text-size / summary difference
/// produces a different string and therefore a clean miss — never a stale render.
struct WarmupSlot<Payload> {
    let identifier: String
    let html: String
    let payload: Payload

    /// The payload iff both the identifier and the rendered HTML match.
    func matched(identifier: String, html: String) -> Payload? {
        (self.identifier == identifier && self.html == html) ? payload : nil
    }
}

/// Single-slot holder for a warmup payload. `take` is single-use: a hit clears the slot;
/// a miss leaves it intact for a later attempt. `discardUnused` releases whatever remains.
@MainActor
final class WarmupSlotBox<Payload> {
    private var slot: WarmupSlot<Payload>?

    func store(identifier: String, html: String, payload: Payload) {
        slot = WarmupSlot(identifier: identifier, html: html, payload: payload)
    }

    func take(identifier: String, html: String) -> Payload? {
        guard let payload = slot?.matched(identifier: identifier, html: html) else { return nil }
        slot = nil
        return payload
    }

    func discardUnused() -> Payload? {
        defer { slot = nil }
        return slot?.payload
    }
}
```

- [ ] **Step 4: Generate project + run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/WarmupSlot.swift YanaTests/ReaderWarmupTests.swift project.yml Yana.xcodeproj
git commit -m "feat(reader): warmup slot value type + single-slot box"
```

---

### Task 2: Shared WebView configuration factory

**Files:**
- Create: `Yana/Reader/ReaderWebView.swift`
- Modify: `Yana/Reader/ReaderWebViewController.swift` (remove the private `processPool`/`imageSchemeHandler` statics and the inline config build in `viewDidLoad`; use the factory)

**Interfaces:**
- Consumes: `ReaderWeb.imageScheme`, `ReaderWeb.linkInterceptionScript` (from `Yana/Aggregators/Utils/ReaderWeb.swift`).
- Produces:
  - `@MainActor enum ReaderWebView { static let processPool: WKProcessPool; static let imageSchemeHandler: ImageSchemeHandler; static func makeConfiguration() -> WKWebViewConfiguration }`
  - `makeConfiguration()` returns a config with the shared process pool, the image scheme handler registered for `ReaderWeb.imageScheme`, and a `WKUserContentController` with the link-interception userscript injected at `.atDocumentStart`. It does **not** add the `linkClickedHandler` message handler — each page adds its own (weakly held).

- [ ] **Step 1: Write the factory**

Create `Yana/Reader/ReaderWebView.swift`:

```swift
import WebKit

/// Shared WebKit plumbing for the reader. Both the live page (`ReaderWebViewController`) and the
/// launch warmer (`ReaderWarmup`) build their web views through `makeConfiguration()` so a warmed
/// web view is byte-for-byte adoptable by a page.
@MainActor
enum ReaderWebView {
    /// Shared across every reader page so the web views run in one Web Content process instead of
    /// spawning one each. The reader prewarms several pages at once, so without a shared pool a
    /// single swipe burst would fork ~10 processes — costly to start and memory-heavy. Sharing the
    /// pool also shares the page cache.
    static let processPool = WKProcessPool()

    /// One stateless image handler for all pages (it only reads from `ImageStore.shared`).
    static let imageSchemeHandler = ImageSchemeHandler()

    /// Configuration with the shared process pool, image scheme handler, and the link-interception
    /// userscript. The per-page `linkClickedHandler` message handler is NOT added here: it is weakly
    /// tied to a view controller, so each page adds its own after obtaining the web view (the warmer
    /// has no view controller, so it leaves the handler off until a page adopts the view).
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.setURLSchemeHandler(imageSchemeHandler, forURLScheme: ReaderWeb.imageScheme)
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: ReaderWeb.linkInterceptionScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        config.userContentController = controller
        return config
    }
}
```

- [ ] **Step 2: Refactor `ReaderWebViewController.viewDidLoad` to use the factory**

In `Yana/Reader/ReaderWebViewController.swift`:

Delete these two private statics (lines ~19-27 — now owned by `ReaderWebView`):

```swift
    private static let processPool = WKProcessPool()
    private static let imageSchemeHandler = ImageSchemeHandler()
```

Replace the configuration-build block in `viewDidLoad` (the lines from `let config = WKWebViewConfiguration()` through `config.userContentController = controller` and the `webView = WKWebView(...)` line) with:

```swift
        let config = ReaderWebView.makeConfiguration()
        // Each page registers its own (weakly held) link message handler on the shared controller.
        config.userContentController.add(WeakScriptMessageHandler(self), name: ReaderWeb.linkClickedHandler)
        webView = WKWebView(frame: view.bounds, configuration: config)
```

Leave everything else in `viewDidLoad` (opacity, delegates, constraints, refresh control, tap zones, observers, `render()`) unchanged.

- [ ] **Step 3: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (no remaining references to `ReaderWebViewController.processPool` / `.imageSchemeHandler`).

- [ ] **Step 4: Run full test suite (refactor must not regress)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderWebView.swift Yana/Reader/ReaderWebViewController.swift project.yml Yana.xcodeproj
git commit -m "refactor(reader): extract shared WKWebView configuration factory"
```

---

### Task 3: Anchor resolution helper

**Files:**
- Modify: `Yana/Services/ArticleResolution.swift`
- Test: `YanaTests/ReaderWarmupTests.swift` (add cases)

**Interfaces:**
- Consumes: `Article` model (`identifier`, `createdAt`); `ModelContext`.
- Produces: `static func fetchNewest(in context: ModelContext) -> Article?` on `ArticleResolution` — the most recent article by `createdAt`, or nil if the store is empty.

- [ ] **Step 1: Write the failing tests**

Append to `ReaderWarmupTests.swift` (inside the struct):

```swift
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func fetchNewestReturnsMostRecentByCreatedAt() throws {
        let context = try makeContext()
        let older = Article(); older.identifier = "old"; older.createdAt = Date(timeIntervalSince1970: 100)
        let newer = Article(); newer.identifier = "new"; newer.createdAt = Date(timeIntervalSince1970: 200)
        context.insert(older); context.insert(newer)
        try context.save()
        #expect(ArticleResolution.fetchNewest(in: context)?.identifier == "new")
    }

    @Test func fetchNewestReturnsNilWhenEmpty() throws {
        let context = try makeContext()
        #expect(ArticleResolution.fetchNewest(in: context) == nil)
    }
```

Add the needed imports at the top of the file (alongside `import Testing`):

```swift
import SwiftData
import Foundation
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: FAIL — `type 'ArticleResolution' has no member 'fetchNewest'`.

- [ ] **Step 3: Implement `fetchNewest`**

In `Yana/Services/ArticleResolution.swift`, add inside the `ArticleResolution` enum (after `fetchByIdentifier`):

```swift
    /// The most recent article by import date, or nil if the library is empty. Used by the launch
    /// warmer when no saved anchor exists (the reader opens to the newest article in that case).
    static func fetchNewest(in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleResolution.swift YanaTests/ReaderWarmupTests.swift
git commit -m "feat(reader): ArticleResolution.fetchNewest for warmup anchor fallback"
```

---

### Task 4: `ReaderWarmup` + `ReaderWarmupStore`

**Files:**
- Modify: `Yana/Reader/WarmupSlot.swift` (add `ReaderWarmupStore` and `ReaderWarmup`) — or create `Yana/Reader/ReaderWarmup.swift`; use a separate file for clarity.
- Create: `Yana/Reader/ReaderWarmup.swift`
- Test: `YanaTests/ReaderWarmupTests.swift` (add anchor-selection case)

**Interfaces:**
- Consumes: `WarmupSlotBox<WKWebView>` (Task 1); `ReaderWebView.makeConfiguration()` (Task 2); `ArticleResolution.fetchByIdentifier` / `.fetchNewest` (Task 3); `ArticleRenderer.fullPageHTML`, `ArticleThemesManager.shared.currentTheme`, `AppSettings`, `AppContainer.shared`, `ReaderWeb.pageBaseURL`.
- Produces:
  - `@MainActor final class ReaderWarmupStore { static let shared: ReaderWarmupStore; func store(identifier: String, html: String, webView: WKWebView); func take(identifier: String, html: String) -> WKWebView?; func discardUnused() }`
    - `discardUnused()` removes any leftover warmed web view from its superview (the off-screen warm host) before clearing.
  - `@MainActor enum ReaderWarmup { static func anchorArticle(savedIdentifier: String?, in context: ModelContext) -> Article?; static func start() }`
    - `anchorArticle`: saved identifier → `fetchByIdentifier`; nil → `fetchNewest`.
    - `start()`: resolves the anchor against `AppContainer.shared.mainContext`, renders HTML, builds a web view via the factory, parents it off-screen in the key window, loads the HTML, and stores it. No-op if no article resolves.

- [ ] **Step 1: Write the failing test (anchor selection)**

Append to `ReaderWarmupTests.swift`:

```swift
    @Test func anchorArticleUsesSavedIdentifierWhenPresent() throws {
        let context = try makeContext()
        let a = Article(); a.identifier = "saved"; a.createdAt = Date(timeIntervalSince1970: 100)
        let b = Article(); b.identifier = "newest"; b.createdAt = Date(timeIntervalSince1970: 200)
        context.insert(a); context.insert(b)
        try context.save()
        #expect(ReaderWarmup.anchorArticle(savedIdentifier: "saved", in: context)?.identifier == "saved")
    }

    @Test func anchorArticleFallsBackToNewestWhenNoSavedIdentifier() throws {
        let context = try makeContext()
        let a = Article(); a.identifier = "old"; a.createdAt = Date(timeIntervalSince1970: 100)
        let b = Article(); b.identifier = "newest"; b.createdAt = Date(timeIntervalSince1970: 200)
        context.insert(a); context.insert(b)
        try context.save()
        #expect(ReaderWarmup.anchorArticle(savedIdentifier: nil, in: context)?.identifier == "newest")
    }

    @Test func anchorArticleFallsBackToNewestWhenSavedIdentifierMissing() throws {
        let context = try makeContext()
        let a = Article(); a.identifier = "only"; a.createdAt = Date(timeIntervalSince1970: 100)
        context.insert(a)
        try context.save()
        #expect(ReaderWarmup.anchorArticle(savedIdentifier: "ghost", in: context)?.identifier == "only")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: FAIL — `type 'ReaderWarmup' has no member 'anchorArticle'`.

- [ ] **Step 3: Implement `ReaderWarmup` + `ReaderWarmupStore`**

Create `Yana/Reader/ReaderWarmup.swift`:

```swift
import SwiftData
import UIKit
import WebKit

/// Single-slot holder for the warmed anchor web view, parked between launch warmup and the first
/// reader page adopting it. Thin concrete wrapper over `WarmupSlotBox<WKWebView>`.
@MainActor
final class ReaderWarmupStore {
    static let shared = ReaderWarmupStore()
    private let box = WarmupSlotBox<WKWebView>()

    func store(identifier: String, html: String, webView: WKWebView) {
        box.store(identifier: identifier, html: html, payload: webView)
    }

    /// Single-use: returns the warmed web view on an identifier + HTML match and clears the slot.
    func take(identifier: String, html: String) -> WKWebView? {
        box.take(identifier: identifier, html: html)
    }

    /// Release a warmed view no page adopted (e.g. the saved anchor was filtered out and a
    /// different article opened first): detach it from the off-screen warm host and clear the slot.
    func discardUnused() {
        box.discardUnused()?.removeFromSuperview()
    }
}

/// Pre-renders the saved anchor article into an off-screen `WKWebView` during launch so the Web
/// Content process spawn + first-document parse + paint happen before the reader's first page is
/// created. The first `ReaderWebViewController` adopts the warmed view when its rendered HTML
/// matches (see `ReaderWebViewController.viewDidLoad`).
@MainActor
enum ReaderWarmup {

    /// The article the reader will most likely open to: the saved anchor if it still exists,
    /// otherwise the newest article (the reader's default when there is no anchor).
    static func anchorArticle(savedIdentifier: String?, in context: ModelContext) -> Article? {
        if let savedIdentifier,
           let article = ArticleResolution.fetchByIdentifier(savedIdentifier, in: context) {
            return article
        }
        return ArticleResolution.fetchNewest(in: context)
    }

    /// Kicked from the scene `.task` before `articleStore.start()`. Returns immediately after
    /// kicking off the async web-view load; the WebKit work proceeds on its own.
    static func start() {
        let context = AppContainer.shared.mainContext
        guard let article = anchorArticle(savedIdentifier: AppSettings().timelineAnchorIdentifier,
                                          in: context) else { return }

        // summaryPending: false — a stored anchor at cold start has no in-flight AI summary job.
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: AppSettings().articleTextSize,
            summaryPending: false
        )

        let webView = WKWebView(frame: .zero, configuration: ReaderWebView.makeConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

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
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
```

- [ ] **Step 4: Generate + run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderWarmupTests`
Expected: PASS (all warmup tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderWarmup.swift YanaTests/ReaderWarmupTests.swift project.yml Yana.xcodeproj
git commit -m "feat(reader): ReaderWarmup pre-renders anchor into off-screen WKWebView"
```

---

### Task 5: Adopt the warmed web view in `ReaderWebViewController`

**Files:**
- Modify: `Yana/Reader/ReaderWebViewController.swift` (`viewDidLoad`)

**Interfaces:**
- Consumes: `ReaderWarmupStore.shared.take(identifier:html:)` (Task 4); `ReaderWebView.makeConfiguration()` (Task 2); `ArticleRenderer.fullPageHTML`.
- Produces: no new symbols — `viewDidLoad` obtains `webView` either by adopting a warmed view (HTML match) or building a fresh one, then wires it identically.

- [ ] **Step 1: Restructure `viewDidLoad` to adopt-or-build**

In `Yana/Reader/ReaderWebViewController.swift`, replace the web-view acquisition portion of `viewDidLoad` (from the `let config = ReaderWebView.makeConfiguration()` block introduced in Task 2 through the `webView = WKWebView(...)` line) with the adopt-or-build sequence below. The wiring that follows (opacity, delegates, constraints, refresh control, tap zones, observers) stays as-is, except the final `render()` call becomes conditional as shown.

```swift
        // Compute the HTML this page would render; it is both the warmup match key and, on a miss,
        // what `render()` will load.
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize,
            summaryPending: summaryPending
        )

        let adoptedWarmedView: Bool
        if let warmed = ReaderWarmupStore.shared.take(identifier: article.identifier, html: html) {
            // Adopt the launch-warmed web view: its document is already parsed (and painted, if it
            // was parented off-screen). Detach from the warm host before re-parenting into this page.
            warmed.removeFromSuperview()
            webView = warmed
            loadedHTML = html                 // mark as already-loaded so `render()` no-ops
            adoptedWarmedView = true
        } else {
            webView = WKWebView(frame: view.bounds, configuration: ReaderWebView.makeConfiguration())
            adoptedWarmedView = false
        }
        // Each page registers its own (weakly held) link message handler on the shared controller.
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(self), name: ReaderWeb.linkClickedHandler
        )
```

Then, at the end of `viewDidLoad`, replace the unconditional `render()` with:

```swift
        if adoptedWarmedView {
            // The document is already loaded; just reveal it. If the load already finished (no
            // delegate was attached during warmup, so `didFinish` won't fire again), fade in now;
            // otherwise the navigation delegate fades it in on `didFinish`.
            if !webView.isLoading {
                UIView.animate(withDuration: CrossFade.duration) { self.webView.alpha = 1 }
            }
        } else {
            render()
        }
```

> Note: the `webView.alpha = 0` line in the existing wiring stays — the adopt path overrides it to `1` only when the load has already finished.

- [ ] **Step 2: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ReaderWebViewController.swift
git commit -m "feat(reader): adopt launch-warmed web view for matching first page"
```

---

### Task 6: Discard an unused warm after the first page

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift` (`configure(articles:index:)`)

**Interfaces:**
- Consumes: `ReaderWarmupStore.shared.discardUnused()` (Task 4).
- Produces: nothing new.

- [ ] **Step 1: Call `discardUnused()` after the first page is set**

In `Yana/Reader/ReaderArticleViewController.swift`, in `configure(articles:index:)`, immediately after the `if let page = makePage(for: self.index) { ... }` block and before `updateStarItem()`, add:

```swift
        // Release any launch-warmed web view the first page did not adopt (e.g. the saved anchor
        // was filtered out of the current tag filter and a different article opened first).
        ReaderWarmupStore.shared.discardUnused()
```

- [ ] **Step 2: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift
git commit -m "feat(reader): discard unused launch warm after first page"
```

---

### Task 7: Kick warmup at launch

**Files:**
- Modify: `Yana/YanaApp.swift` (scene `.task`)

**Interfaces:**
- Consumes: `ReaderWarmup.start()` (Task 4).
- Produces: nothing new.

- [ ] **Step 1: Kick warmup before the store bootstrap**

In `Yana/YanaApp.swift`, change the scene `.task` from:

```swift
                .task { articleStore.start() }
```

to:

```swift
                // Warm WebKit with the anchor article before the store bootstrap, so the Web Content
                // process spawn + first-document parse/paint precede the reader's first page.
                .task { ReaderWarmup.start(); articleStore.start() }
```

- [ ] **Step 2: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Yana/YanaApp.swift
git commit -m "feat(reader): kick anchor WebKit warmup at launch"
```

---

### Task 8: Manual verification

**Files:** none.

- [ ] **Step 1: Cold-start the app on the simulator/device**

Launch the app fresh (kill first) with at least one article in the library and a saved timeline anchor. Confirm the reader opens to the anchor article and the first article paints with no visible blank/white flash and no regression in link taps, pull-to-refresh, or star.

- [ ] **Step 2: Verify filter-mismatch path**

Apply a tag filter that excludes the saved anchor, background the app, relaunch. Confirm the reader opens to a valid (different) article with no crash and no lingering off-screen web view (no visual artifact, scrolling unaffected).

- [ ] **Step 3: Verify appearance-change path**

Change the reader theme or text size, then cold-start. Confirm the first article renders correctly at the new appearance (warmed HTML is a clean miss; fresh render used).

---

## Self-Review

**Spec coverage:**
- Launch kickoff from scene `.task` → Task 7. ✓
- Anchor resolution (saved id → `fetchByIdentifier`; nil → `fetchNewest`) → Tasks 3, 4. ✓
- Render with current theme/text size, `summaryPending: false` → Task 4. ✓
- Shared configuration factory (process pool, image handler, userscript, no message handler) → Task 2. ✓
- Off-screen paint in key window, graceful degrade when no window → Task 4. ✓
- Single-slot store with HTML-equality match gate, single-use `take`, `discardUnused` removing from superview → Tasks 1, 4. ✓
- Adoption in `viewDidLoad` (remove from host, add message handler, delegates, `loadedHTML` no-op, fade-in on `!isLoading` else `didFinish`) → Task 5. ✓
- `discardUnused` after first page → Task 6. ✓
- Process-termination recovery unaffected (untouched `webViewWebContentProcessDidTerminate`) → no task needed. ✓
- Edges (filtered out, empty library, summaryPending mismatch) → covered by HTML-equality miss + `anchorArticle` nil guard; manual checks in Task 8. ✓
- No user-facing strings → confirmed, no localization task. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `WarmupSlot`/`WarmupSlotBox` (Task 1) → `ReaderWarmupStore` wraps `WarmupSlotBox<WKWebView>` (Task 4); `ReaderWebView.makeConfiguration()` (Task 2) used in Tasks 4 & 5; `ArticleResolution.fetchNewest` (Task 3) used in Task 4; `ReaderWarmup.start()`/`anchorArticle` (Task 4) used in Tasks 5, 6, 7. Names consistent throughout. ✓
