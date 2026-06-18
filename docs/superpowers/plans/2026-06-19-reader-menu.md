# Reader Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-right overflow menu to the reader with Force update, Copy link, Summarize, and Go to feed.

**Architecture:** A native `UIMenu` on a new nav-bar `UIBarButtonItem` in `ReaderArticleViewController`, rebuilt per-presentation so conditional items reflect the current article and AI state. New on-demand summarization lives in `AggregationService`. SwiftUI (`ReaderScreen`) owns the handlers, AI-readiness check, feed-editor sheet, and a reload token that tells the reader to re-render after a summary lands. Pure helpers (`AIReadiness`, `ReaderMenuBuilder`) carry the testable logic.

**Tech Stack:** Swift 6, SwiftUI, UIKit (UIPageViewController/WKWebView reader), SwiftData, Swift Testing.

## Global Constraints

- Platform: iOS 26.0+; Swift 6 strict concurrency, `@MainActor` throughout.
- All new user-facing strings MUST be added to `Yana/Resources/Localizable.xcstrings` with a German (`de`) translation marked `"state" : "translated"`. German uses Apple style (infinitive for actions, no Du/Sie).
- SwiftData is the source of truth: views read via `@Query`; `AggregationService` writes.
- New source/test files are picked up by XcodeGen globs (`Yana`, `YanaTests`); run `xcodegen generate` after adding any new file before building.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) and `@MainActor`.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`.

---

### Task 1: On-demand summarization in AggregationService

**Files:**
- Modify: `Yana/Services/AggregationService.swift` (add `summarize(_:)` after `forceReload(article:)`, around line 262)
- Create: `YanaTests/AggregationSummarizeTests.swift`

**Interfaces:**
- Consumes: existing private `currentAIProcessor() -> AIProcessing`; `AggregatedArticle` initializer; `AIOptions`.
- Produces: `@discardableResult func summarize(_ article: Article) async -> Bool` — runs a summarize-only AI pass on a single article, writes the resulting non-empty `summary` back onto the `Article`, saves the context, and returns `true`; returns `false` (article unchanged) when AI produced no summary (failure, drop, or empty content).

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/AggregationSummarizeTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService.summarize")
struct AggregationSummarizeTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Stub processor that stamps a fixed summary onto every input article.
    private struct StubSummarizer: AIProcessing {
        let summary: String
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
            input.map { var a = $0; a.summary = summary; return a }
        }
    }

    /// Stub processor that drops everything (mirrors AI failure / invalid JSON).
    private struct DroppingProcessor: AIProcessing {
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] { [] }
    }

    @Test func writesSummaryAndReturnsTrue() async throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "i", url: "https://x", content: "<p>body</p>")
        context.insert(article)

        let service = AggregationService(context: context, aiProcessor: StubSummarizer(summary: "Short summary."))
        let ok = await service.summarize(article)

        #expect(ok == true)
        #expect(article.summary == "Short summary.")
    }

    @Test func failureLeavesArticleUnchanged() async throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "i", url: "https://x", content: "<p>body</p>", summary: "old")
        context.insert(article)

        let service = AggregationService(context: context, aiProcessor: DroppingProcessor())
        let ok = await service.summarize(article)

        #expect(ok == false)
        #expect(article.summary == "old")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationSummarizeTests`
Expected: FAIL — `value of type 'AggregationService' has no member 'summarize'` (compile error).

- [ ] **Step 3: Implement `summarize(_:)`**

In `Yana/Services/AggregationService.swift`, add this method immediately after `forceReload(article:)` (after line 262, before `// MARK: - Core per-feed run`):

```swift
    /// Summarize a single article on demand, independent of its feed's AI options. Runs a
    /// summarize-only pass through the current AI processor, copies the resulting summary onto
    /// the article (source content is left untouched), and saves. Returns false — leaving the
    /// article unchanged — when no summary was produced (AI failure, dropped item, or empty
    /// content). Callers should only invoke this when AI is configured (see `AIReadiness`).
    @discardableResult
    func summarize(_ article: Article) async -> Bool {
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: article.rawContent, content: article.content, date: article.date,
            author: article.author, iconURL: article.iconURL
        )
        let processed = await currentAIProcessor().process([seed], ai: AIOptions(summarize: true))
        guard let summary = processed.first?.summary, !summary.isEmpty else { return false }
        article.summary = summary
        try? context.save()
        return true
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationSummarizeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios/.claude/worktrees/bridge-cse_01XyRqAAXkPN4CGyh31nWujt
xcodegen generate
git add Yana/Services/AggregationService.swift YanaTests/AggregationSummarizeTests.swift
git commit -m "feat(reader): add on-demand single-article summarization to AggregationService"
```

---

### Task 2: AI-readiness helper

**Files:**
- Modify: `Yana/Models/AppSettings.swift` (add `apiKeyItem` to the `AIProvider` enum, after `baseURL` around line 54)
- Create: `Yana/Services/AIReadiness.swift`
- Create: `YanaTests/AIReadinessTests.swift`

**Interfaces:**
- Consumes: `AIProvider`, `KeychainService.APIKeyItem`, `AppleIntelligenceAvailability`, `AppleIntelligenceClient`.
- Produces:
  - `var AIProvider.apiKeyItem: KeychainService.APIKeyItem?` — the Keychain item holding this provider's key (`nil` for `.none` / `.appleIntelligence`).
  - `enum AIReadiness { static func isReady(provider:loadKey:appleAvailability:) -> Bool }` — true when the active provider can actually run: a cloud provider with a non-empty stored key, or Apple Intelligence reporting `.available`. `loadKey` and `appleAvailability` are injectable for tests.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/AIReadinessTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
@Suite("AIReadiness")
struct AIReadinessTests {
    @Test func noneIsNeverReady() {
        #expect(AIReadiness.isReady(provider: .none, loadKey: { _ in "k" }, appleAvailability: { .available }) == false)
    }

    @Test func cloudProviderReadyOnlyWithKey() {
        #expect(AIReadiness.isReady(provider: .openai, loadKey: { _ in "sk-123" }, appleAvailability: { .deviceNotEligible }) == true)
        #expect(AIReadiness.isReady(provider: .openai, loadKey: { _ in "" }, appleAvailability: { .available }) == false)
        #expect(AIReadiness.isReady(provider: .openai, loadKey: { _ in nil }, appleAvailability: { .available }) == false)
    }

    @Test func appleIntelligenceReadyOnlyWhenAvailable() {
        #expect(AIReadiness.isReady(provider: .appleIntelligence, loadKey: { _ in nil }, appleAvailability: { .available }) == true)
        #expect(AIReadiness.isReady(provider: .appleIntelligence, loadKey: { _ in nil }, appleAvailability: { .notEnabled }) == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIReadinessTests`
Expected: FAIL — `cannot find 'AIReadiness' in scope`.

- [ ] **Step 3a: Add `apiKeyItem` to `AIProvider`**

In `Yana/Models/AppSettings.swift`, inside the `AIProvider` enum (after the `baseURL` computed property that ends around line 54), add:

```swift
    /// Keychain item holding this provider's API key. `nil` for providers that need no key
    /// (`.none`, on-device `.appleIntelligence`).
    var apiKeyItem: KeychainService.APIKeyItem? {
        switch self {
        case .none, .appleIntelligence: return nil
        case .openai: return .openaiAPIKey
        case .anthropic: return .anthropicAPIKey
        case .gemini: return .geminiAPIKey
        case .mistral: return .mistralAPIKey
        case .qwen: return .qwenAPIKey
        case .deepseek: return .deepseekAPIKey
        }
    }
```

- [ ] **Step 3b: Create `AIReadiness`**

Create `Yana/Services/AIReadiness.swift`:

```swift
import Foundation

/// Decides whether AI post-processing can actually run right now, based on the active provider:
/// a cloud provider needs a non-empty stored key; Apple Intelligence needs on-device availability.
/// `loadKey` / `appleAvailability` are injectable so the logic stays unit-testable.
enum AIReadiness {
    static func isReady(
        provider: AIProvider,
        loadKey: (KeychainService.APIKeyItem) -> String? = { KeychainService.loadAPIKey(for: $0) },
        appleAvailability: () -> AppleIntelligenceAvailability = { AppleIntelligenceClient().availability }
    ) -> Bool {
        switch provider {
        case .none:
            return false
        case .appleIntelligence:
            return appleAvailability() == .available
        default:
            guard let item = provider.apiKeyItem else { return false }
            return !(loadKey(item) ?? "").isEmpty
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIReadinessTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios/.claude/worktrees/bridge-cse_01XyRqAAXkPN4CGyh31nWujt
xcodegen generate
git add Yana/Models/AppSettings.swift Yana/Services/AIReadiness.swift YanaTests/AIReadinessTests.swift
git commit -m "feat(reader): add AIReadiness helper and AIProvider.apiKeyItem"
```

---

### Task 3: Reader menu item visibility helper

**Files:**
- Create: `Yana/Reader/ReaderMenuBuilder.swift`
- Create: `YanaTests/ReaderMenuBuilderTests.swift`

**Interfaces:**
- Produces:
  - `struct ReaderMenuConfig: Equatable { var showCopyLink: Bool; var showSummarize: Bool; var showGoToFeed: Bool }`
  - `enum ReaderMenuBuilder { static func config(hasURL: Bool, hasFeed: Bool, aiReady: Bool) -> ReaderMenuConfig }` — Force update is always present (not represented here); Copy link appears when the article has a URL, Summarize when AI is ready, Go to feed when the article has a feed.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/ReaderMenuBuilderTests.swift`:

```swift
import Testing
@testable import Yana

@Suite("ReaderMenuBuilder")
struct ReaderMenuBuilderTests {
    @Test func allVisibleWhenEverythingPresent() {
        let c = ReaderMenuBuilder.config(hasURL: true, hasFeed: true, aiReady: true)
        #expect(c == ReaderMenuConfig(showCopyLink: true, showSummarize: true, showGoToFeed: true))
    }

    @Test func copyLinkHiddenWithoutURL() {
        #expect(ReaderMenuBuilder.config(hasURL: false, hasFeed: true, aiReady: true).showCopyLink == false)
    }

    @Test func summarizeHiddenWhenAINotReady() {
        #expect(ReaderMenuBuilder.config(hasURL: true, hasFeed: true, aiReady: false).showSummarize == false)
    }

    @Test func goToFeedHiddenWithoutFeed() {
        #expect(ReaderMenuBuilder.config(hasURL: true, hasFeed: false, aiReady: true).showGoToFeed == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderMenuBuilderTests`
Expected: FAIL — `cannot find 'ReaderMenuBuilder' in scope`.

- [ ] **Step 3: Implement the helper**

Create `Yana/Reader/ReaderMenuBuilder.swift`:

```swift
import Foundation

/// Which conditional items the reader's overflow menu should show for the current article.
/// Force update is unconditional and not represented here.
struct ReaderMenuConfig: Equatable {
    var showCopyLink: Bool
    var showSummarize: Bool
    var showGoToFeed: Bool
}

enum ReaderMenuBuilder {
    static func config(hasURL: Bool, hasFeed: Bool, aiReady: Bool) -> ReaderMenuConfig {
        ReaderMenuConfig(showCopyLink: hasURL, showSummarize: aiReady, showGoToFeed: hasFeed)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderMenuBuilderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios/.claude/worktrees/bridge-cse_01XyRqAAXkPN4CGyh31nWujt
xcodegen generate
git add Yana/Reader/ReaderMenuBuilder.swift YanaTests/ReaderMenuBuilderTests.swift
git commit -m "feat(reader): add ReaderMenuBuilder visibility helper"
```

---

### Task 4: Add the menu and callbacks to ReaderArticleViewController

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift`

**Interfaces:**
- Consumes: `ReaderMenuBuilder.config(hasURL:hasFeed:aiReady:)`; existing `onRefresh`, `currentArticle()`, `displayedWebVC`.
- Produces (new public surface on `ReaderArticleViewController`, set by `ReaderHostView`):
  - `var onCopyLink: ((Article) -> Void)?`
  - `var onSummarize: ((Article) -> Void)?`
  - `var onGoToFeed: ((Feed) -> Void)?`
  - `var aiReady: Bool` (default `false`)
  - `var isSummarizing: Bool` (default `false`)
  - `func reloadCurrentPage()` — re-renders the currently displayed page's web view.

This task has no unit test (UIKit chrome); it is verified by a successful build plus the helper tests from Task 3. A manual verification step is included.

- [ ] **Step 1: Add the new callbacks and flags**

In `Yana/Reader/ReaderArticleViewController.swift`, after the existing callback declarations (after line 14, `var onRefresh: (() -> Void)?`), add:

```swift
    var onCopyLink: ((Article) -> Void)?
    var onSummarize: ((Article) -> Void)?
    var onGoToFeed: ((Feed) -> Void)?
    /// Whether AI is configured/available; gates the Summarize menu item. Set by the host.
    var aiReady = false
    /// True while an on-demand summary is in flight; disables the Summarize menu item.
    var isSummarizing = false
```

- [ ] **Step 2: Add a stored menu bar-button item**

In the same file, after the existing bar-item declarations (after line 26, `private var shareItem: UIBarButtonItem!`), add:

```swift
    private var menuItem: UIBarButtonItem!
```

- [ ] **Step 3: Build the menu and place it at the right edge**

In `configureNavigationItems()`, replace the right-bar-items block (lines 86–94, from `let library = UIBarButtonItem(` through `navigationItem.rightBarButtonItems = [library, starItem]`) with:

```swift
        let library = UIBarButtonItem(
            image: UIImage(systemName: "books.vertical"),
            style: .plain, target: self, action: #selector(showSettings)
        )
        library.accessibilityLabel = String(localized: "Library")
        starItem = UIBarButtonItem(image: UIImage(systemName: "star"), style: .plain, target: self, action: #selector(toggleStar))

        // Overflow menu, rebuilt each time it opens so conditional items track the current
        // article + AI state. UIDeferredMenuElement.uncached re-invokes the provider per present.
        menuItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.buildMenuActions() ?? [])
                }
            ])
        )
        menuItem.accessibilityLabel = String(localized: "More actions")
        // rightBarButtonItems is ordered edge-inward: [menu, library, star] puts the overflow
        // menu at the screen edge, then the library button, then the star.
        navigationItem.rightBarButtonItems = [menuItem, library, starItem]
```

- [ ] **Step 4: Implement the menu-action builder**

In the same file, in the `// MARK: - Actions` section (after `toggleStar()`, around line 174), add:

```swift
    private func buildMenuActions() -> [UIMenuElement] {
        guard let article = currentArticle() else { return [] }
        let config = ReaderMenuBuilder.config(
            hasURL: !article.url.isEmpty, hasFeed: article.feed != nil, aiReady: aiReady
        )
        var actions: [UIMenuElement] = []

        actions.append(UIAction(
            title: String(localized: "Force update"),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in self?.onRefresh?() })

        if config.showCopyLink {
            actions.append(UIAction(
                title: String(localized: "Copy link"),
                image: UIImage(systemName: "link")
            ) { [weak self] _ in self?.onCopyLink?(article) })
        }

        if config.showSummarize {
            let summarize = UIAction(
                title: String(localized: "Summarize"),
                image: UIImage(systemName: "sparkles")
            ) { [weak self] _ in self?.onSummarize?(article) }
            if isSummarizing { summarize.attributes = .disabled }
            actions.append(summarize)
        }

        if config.showGoToFeed, let feed = article.feed {
            actions.append(UIAction(
                title: String(localized: "Go to feed"),
                image: UIImage(systemName: "dot.radiowaves.up.forward")
            ) { [weak self] _ in self?.onGoToFeed?(feed) })
        }

        return actions
    }

    func reloadCurrentPage() {
        displayedWebVC?.reload()
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios/.claude/worktrees/bridge-cse_01XyRqAAXkPN4CGyh31nWujt
git add Yana/Reader/ReaderArticleViewController.swift
git commit -m "feat(reader): add overflow menu with force update, copy link, summarize, go to feed"
```

---

### Task 5: Wire the menu into SwiftUI (host + screen + AppState)

**Files:**
- Modify: `Yana/Models/AppState.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (both `ReaderHostView` and `ReaderScreen`)

**Interfaces:**
- Consumes: `AggregationService.summarize(_:)` (Task 1), `AIReadiness.isReady(provider:)` (Task 2), `ReaderArticleViewController` new surface (Task 4), `FeedEditorView(feed:)`.
- Produces: `AppState.feedToEdit: Feed?`; `ReaderHostView` gains `onCopyLink`/`onSummarize`/`onGoToFeed` callbacks plus `aiReady`, `isSummarizing`, and `reloadToken` inputs; `ReaderScreen` drives them.

This task is verified by a successful build plus a manual smoke test (no unit test for the UIKit/SwiftUI bridge).

- [ ] **Step 1: Add `feedToEdit` to AppState**

In `Yana/Models/AppState.swift`, add a field after `var showFilter = false` (line 11):

```swift
    /// When non-nil, the reader presents `FeedEditorView` for this feed as a sheet.
    var feedToEdit: Feed?
```

- [ ] **Step 2: Extend ReaderHostView's inputs and wiring**

In `Yana/Reader/ReaderHostView.swift`, add new stored properties to `ReaderHostView` after `var onToggleStar: ((Article) -> Void)?` (line 15):

```swift
    var onCopyLink: ((Article) -> Void)?
    var onSummarize: ((Article) -> Void)?
    var onGoToFeed: ((Feed) -> Void)?
    let aiReady: Bool
    let isSummarizing: Bool
    /// Bumped by the host after a summary is written so the displayed page re-renders.
    let reloadToken: Int
```

In `makeUIViewController(context:)`, after `reader.onRefresh = onRefresh` (line 24), add:

```swift
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
        reader.onGoToFeed = onGoToFeed
        reader.aiReady = aiReady
        reader.isSummarizing = isSummarizing
        context.coordinator.lastReloadToken = reloadToken
```

In `updateUIViewController(_:context:)`, after `reader.onRefresh = onRefresh` (line 39), add:

```swift
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
        reader.onGoToFeed = onGoToFeed
        reader.aiReady = aiReady
        reader.isSummarizing = isSummarizing
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            reader.reloadCurrentPage()
        }
```

In the `Coordinator` class, add a stored property after `var reader: ReaderArticleViewController?` (line 47):

```swift
        var lastReloadToken = 0
```

- [ ] **Step 3: Add state, AI-readiness, and handlers to ReaderScreen**

In `Yana/Reader/ReaderHostView.swift`, in `ReaderScreen`, add state after `@State private var didRestoreAnchor = false` (line 61):

```swift
    @State private var isSummarizing = false
    @State private var reloadToken = 0
    @State private var summarizeFailed = false
```

Add a computed property after `private var starredTag: Tag? { ... }` (line 71):

```swift
    private var aiReady: Bool { AIReadiness.isReady(provider: settings.activeAIProvider) }
```

- [ ] **Step 4: Pass the new inputs into ReaderHostView**

In `ReaderScreen.body`, replace the `ReaderHostView( ... )` call (lines 87–95) with:

```swift
                ReaderHostView(
                    articles: articles,
                    currentIndex: $appState.currentIndex,
                    isRefreshing: UpdateActivity.shared.isUpdating || isSummarizing,
                    onRefresh: triggerRefresh,
                    onShowFilter: { appState.showFilter = true },
                    onShowSettings: { appState.showSettings = true },
                    onToggleStar: toggleStar,
                    onCopyLink: copyLink,
                    onSummarize: summarize,
                    onGoToFeed: goToFeed,
                    aiReady: aiReady,
                    isSummarizing: isSummarizing,
                    reloadToken: reloadToken
                )
```

- [ ] **Step 5: Add the feed-editor sheet and summarize-failure alert**

In `ReaderScreen.body`, after the `.sheet(isPresented: $appState.showFilter, ...)` line (line 100), add:

```swift
        .sheet(item: $appState.feedToEdit) { feed in
            NavigationStack { FeedEditorView(feed: feed) }
        }
        .alert("Summarize Failed", isPresented: $summarizeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not summarize this article. Please try again.")
        }
```

- [ ] **Step 6: Implement the handlers**

In `ReaderScreen`, after `toggleStar(_:)` (after line 120), add:

```swift
    private func copyLink(_ article: Article) {
        UIPasteboard.general.string = article.url
    }

    private func goToFeed(_ feed: Feed) {
        appState.feedToEdit = feed
    }

    private func summarize(_ article: Article) {
        guard !isSummarizing else { return }
        isSummarizing = true
        Task {
            let ok = await AggregationService(context: modelContext).summarize(article)
            isSummarizing = false
            if ok {
                reloadToken += 1
            } else {
                summarizeFailed = true
            }
        }
    }
```

- [ ] **Step 7: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Manual smoke test**

Run the app in the simulator and confirm:
- The reader's top-right shows the `⋯` menu at the edge, with Library and Star to its left.
- Menu shows Force update + Copy link always; Summarize only when an AI provider is configured (or Apple Intelligence is available); Go to feed only when the article has a feed.
- Copy link puts the URL on the clipboard; Force update refreshes; Summarize shows the nav-bar spinner and then a summary block appears in the article (or a "Summarize Failed" alert); Go to feed opens the feed editor sheet.

- [ ] **Step 9: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios/.claude/worktrees/bridge-cse_01XyRqAAXkPN4CGyh31nWujt
git add Yana/Models/AppState.swift Yana/Reader/ReaderHostView.swift
git commit -m "feat(reader): wire overflow menu handlers, feed-editor sheet, and summary reload"
```

---

### Task 6: Localization

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: the literal strings introduced in Tasks 4–5.

Note: `"Summarize"` already exists in the catalog (German `"Zusammenfassen"`) — do not re-add it. New keys to add: `"Force update"`, `"Copy link"`, `"Go to feed"`, `"More actions"`, `"Summarize Failed"`, `"Could not summarize this article. Please try again."`.

- [ ] **Step 1: Add the new string entries**

In `Yana/Resources/Localizable.xcstrings`, add the following key/value entries inside the top-level `"strings"` object (keys are sorted alphabetically by Xcode; exact position does not affect correctness). Each entry:

```json
    "Copy link" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Link kopieren"
          }
        }
      }
    },
    "Could not summarize this article. Please try again." : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Dieser Artikel konnte nicht zusammengefasst werden. Bitte erneut versuchen."
          }
        }
      }
    },
    "Force update" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Aktualisieren erzwingen"
          }
        }
      }
    },
    "Go to feed" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Zum Feed"
          }
        }
      }
    },
    "More actions" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Weitere Aktionen"
          }
        }
      }
    },
    "Summarize Failed" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Zusammenfassung fehlgeschlagen"
          }
        }
      }
    },
```

- [ ] **Step 2: Verify the catalog is valid JSON**

Run: `python3 -c "import json; json.load(open('Yana/Resources/Localizable.xcstrings'))" && echo OK`
Expected: `OK` (no JSON parse error).

- [ ] **Step 3: Build to confirm the catalog compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios/.claude/worktrees/bridge-cse_01XyRqAAXkPN4CGyh31nWujt
git add Yana/Resources/Localizable.xcstrings
git commit -m "i18n(reader): add German translations for reader menu strings"
```

---

## Final verification

- [ ] Run the full test suite: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` — expected: all tests pass, including the new `AggregationSummarizeTests`, `AIReadinessTests`, `ReaderMenuBuilderTests`.
