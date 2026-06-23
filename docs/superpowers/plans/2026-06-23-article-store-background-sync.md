# Unified Background-Loaded Article Store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load the whole article dataset as a lightweight, background-loaded, in-sync index that both the reader and the article list consume, so opening the list is instant; and make the current article clearly visible in the list.

**Architecture:** A `@MainActor @Observable ArticleStore` holds `[ArticleSummary]` (Sendable, HTML-free). A background `@ModelActor` loads the index off the main thread and a `ModelContext.didSave` observer keeps it in sync. The reader pager and the list both read summaries; the pager resolves the full `Article` per page by `PersistentIdentifier` on demand. The `TimelineWindow` system is removed.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`@Model`, `FetchDescriptor`, `@ModelActor`, `propertiesToFetch`), UIKit (`UIPageViewController`), Swift Testing (`import Testing`).

## Global Constraints

- Platform: iOS 26.0+ (iPhone and iPad).
- Swift 6 strict concurrency; `@MainActor` annotations throughout; cross-actor values must be `Sendable`.
- All user-facing strings localizable; every new string MUST have a German (`de`) entry in `Yana/Resources/Localizable.xcstrings` marked `"state" : "translated"` (Apple style: infinitive for actions, no "Du"/"Sie").
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) under `@MainActor`; in-memory SwiftData via `ModelConfiguration(isStoredInMemoryOnly: true)`.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build` / `test`.
- After any source file is added/removed, run `xcodegen generate` before building (project.yml globs `Yana/**`).

---

### Task 1: `ArticleSummary` value type + filter/identity protocols

**Files:**
- Create: `Yana/Models/ArticleSummary.swift`
- Modify: `Yana/Utilities/TimelineFiltering.swift`
- Modify: `Yana/Aggregators/ArticleSearch.swift` (no behavior change — see note)
- Test: `YanaTests/ArticleSummaryTests.swift`

**Interfaces:**
- Produces:
  - `struct ArticleSummary: Identifiable, Sendable, Hashable` with `id: String { identifier }` and stored: `persistentID: PersistentIdentifier`, `identifier: String`, `title: String`, `feedName: String`, `feedLogoHash: String?`, `author: String`, `date: Date`, `createdAt: Date`, `tagNames: Set<String>`, `isStarred: Bool`.
  - `init(_ article: Article)` mapping initializer.
  - `protocol TimelineFilterable { var filterTagNames: [String] { get }; var filterFeedName: String? { get } }` with conformances on `Article` and `ArticleSummary`.
  - `protocol TimelineIdentifiable { var identifier: String { get } }` with conformances on `Article` and `ArticleSummary`.
  - `TagFilter.apply` / `FeedFilter.apply` / `TimelinePageIndex.index` / `TimelineAnchor.index` become generic over these protocols.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSummaryTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSummary")
struct ArticleSummaryTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func mapsArticleFieldsTagsAndStar() throws {
        let context = try makeContext()
        let starred = Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true)
        let news = Yana.Tag(name: "News")
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f")
        let article = Article(title: "Hello", identifier: "a1", url: "u", content: "<p>body</p>",
                              date: .now, author: "Ada")
        article.feed = feed
        article.tags = [news, starred]
        context.insert(feed); context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)

        #expect(summary.identifier == "a1")
        #expect(summary.title == "Hello")
        #expect(summary.feedName == "Acme")
        #expect(summary.author == "Ada")
        #expect(summary.tagNames == ["News", Yana.Tag.starredName])
        #expect(summary.isStarred == true)
        #expect(summary.id == "a1")
        #expect(summary.persistentID == article.persistentModelID)
    }

    @Test func summaryConformsToFilterAndIdentityProtocols() throws {
        let context = try makeContext()
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f")
        let article = Article(title: "T", identifier: "a2", url: "u")
        article.feed = feed
        article.tags = [Yana.Tag(name: "Tech")]
        context.insert(feed); context.insert(article)
        let summary = ArticleSummary(article)

        #expect(summary.filterFeedName == "Acme")
        #expect(summary.filterTagNames == ["Tech"])
        #expect((summary as TimelineIdentifiable).identifier == "a2")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummary`
Expected: FAIL — `ArticleSummary` is undefined (compile error).

- [ ] **Step 3: Create `ArticleSummary`**

Create `Yana/Models/ArticleSummary.swift`:

```swift
import Foundation
import SwiftData

/// Lightweight, `Sendable` snapshot of an `Article`'s timeline/list metadata — no HTML.
/// Both the reader pager and the article list browse these; the full `Article` (with
/// `content`) is resolved per page by `persistentID` only when a page renders.
struct ArticleSummary: Identifiable, Sendable, Hashable {
    let persistentID: PersistentIdentifier
    let identifier: String
    let title: String
    let feedName: String
    let feedLogoHash: String?
    let author: String
    let date: Date
    let createdAt: Date
    let tagNames: Set<String>
    let isStarred: Bool

    var id: String { identifier }

    init(_ article: Article) {
        persistentID = article.persistentModelID
        identifier = article.identifier
        title = article.title
        feedName = article.feed?.name ?? ""
        feedLogoHash = article.feed?.logoHash
        author = article.author
        date = article.date
        createdAt = article.createdAt
        tagNames = Set(article.tags.map(\.name))
        isStarred = article.isStarred
    }
}
```

- [ ] **Step 4: Add the filter/identity protocols and make the timeline helpers generic**

Replace the whole body of `Yana/Utilities/TimelineFiltering.swift` with:

```swift
import Foundation

/// Items the timeline filters operate on. Both the full `Article` and the lightweight
/// `ArticleSummary` conform, so the same filter pipeline serves the reader and the list.
protocol TimelineFilterable {
    var filterTagNames: [String] { get }
    var filterFeedName: String? { get }
}

/// Items addressable by their stable `identifier` (the timeline anchor key).
protocol TimelineIdentifiable {
    var identifier: String { get }
}

extension Article: TimelineFilterable {
    var filterTagNames: [String] { tags.map(\.name) }
    var filterFeedName: String? { feed?.name }
}

extension Article: TimelineIdentifiable {}

extension ArticleSummary: TimelineFilterable {
    var filterTagNames: [String] { Array(tagNames) }
    var filterFeedName: String? { feedName.isEmpty ? nil : feedName }
}

extension ArticleSummary: TimelineIdentifiable {}

/// Filters the timeline by active tags. OR semantics: an item is shown if it has at
/// least one tag that is *not* disabled. Untagged items are shown only when
/// `includeUntagged` is true.
enum TagFilter {
    static func apply<T: TimelineFilterable>(
        to items: [T], disabledTagNames: Set<String>, includeUntagged: Bool
    ) -> [T] {
        items.filter { item in
            let names = item.filterTagNames
            if names.isEmpty { return includeUntagged }
            return names.contains { !disabledTagNames.contains($0) }
        }
    }
}

/// Filters the timeline by active feeds. An item is shown unless its source feed is
/// disabled. Items whose feed has been deleted (`filterFeedName == nil`) are always shown.
enum FeedFilter {
    static func apply<T: TimelineFilterable>(to items: [T], disabledFeedNames: Set<String>) -> [T] {
        guard !disabledFeedNames.isEmpty else { return items }
        return items.filter { item in
            guard let name = item.filterFeedName else { return true }
            return !disabledFeedNames.contains(name)
        }
    }
}

/// Resolves an item `identifier` to its index in the currently displayed list.
/// Returns `nil` when the identifier is missing.
enum TimelinePageIndex {
    static func index<T: TimelineIdentifiable>(of identifier: String?, in items: [T]) -> Int? {
        guard let identifier else { return nil }
        return items.firstIndex { $0.identifier == identifier }
    }
}

/// Resolves the persisted timeline anchor to an index in the displayed list, falling back
/// to the newest item (last index in the ascending timeline) when missing.
enum TimelineAnchor {
    static func index<T: TimelineIdentifiable>(for identifier: String?, in items: [T]) -> Int {
        TimelinePageIndex.index(of: identifier, in: items) ?? max(0, items.count - 1)
    }
}
```

Note: `ArticleSearch.swift` is unchanged — it keeps operating on `[Article]` for its existing tests. The list's content search moves to a predicate fetch (Task 6); `ArticleSearch` is no longer called from the list but remains valid.

- [ ] **Step 5: Regenerate project, run the new test + the existing filtering/anchor suites**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:YanaTests/ArticleSummary \
  -only-testing:YanaTests/TimelineFilteringTests \
  -only-testing:YanaTests/TimelinePageIndexTests
```
Expected: PASS. Existing `[Article]` callers still compile via the generic signatures.

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/ArticleSummary.swift Yana/Utilities/TimelineFiltering.swift Yana.xcodeproj YanaTests/ArticleSummaryTests.swift
git commit -m "feat(model): add ArticleSummary and generic timeline filters"
```

---

### Task 2: `ArticleStore` + background loader + `didSave` sync

**Files:**
- Create: `Yana/Services/ArticleStore.swift`
- Test: `YanaTests/ArticleStoreTests.swift`

**Interfaces:**
- Consumes: `ArticleSummary(_:)` from Task 1.
- Produces:
  - `@ModelActor actor ArticleSummaryLoader` with `func load() throws -> [ArticleSummary]` (ascending `createdAt`, light `propertiesToFetch`, `feed`/`tags` prefetched).
  - `@MainActor @Observable final class ArticleStore` with `private(set) var summaries: [ArticleSummary]`, `private(set) var hasLoaded: Bool`, `init(container: ModelContainer)`, `func start()`, and `func refreshNow() async` (test seam that performs one synchronous-awaited reload).

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleStoreTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleStore")
struct ArticleStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func insertArticle(_ id: String, into context: ModelContext, createdAt: Date) {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        article.createdAt = createdAt
        context.insert(feed); context.insert(article)
    }

    @Test func loadsExistingArticlesChronologically() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("old", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("new", into: context, createdAt: Date(timeIntervalSince1970: 2))
        try context.save()

        let store = ArticleStore(container: container)
        await store.refreshNow()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.map(\.identifier) == ["old", "new"])
    }

    @Test func reflectsInsertOnRefresh() async throws {
        let container = try makeContainer()
        let store = ArticleStore(container: container)
        await store.refreshNow()
        #expect(store.summaries.isEmpty)

        insertArticle("x", into: container.mainContext, createdAt: .now)
        try container.mainContext.save()
        await store.refreshNow()

        #expect(store.summaries.map(\.identifier) == ["x"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStore`
Expected: FAIL — `ArticleStore` undefined.

- [ ] **Step 3: Implement the store + loader**

Create `Yana/Services/ArticleStore.swift`:

```swift
import Foundation
import SwiftData

/// Loads the lightweight article index off the main thread. `@ModelActor` gives it a private
/// `ModelContext`; it maps to `Sendable` `ArticleSummary` values that cross back to the main actor.
@ModelActor
actor ArticleSummaryLoader {
    func load() throws -> [ArticleSummary] {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        // Only the light columns; HTML (`content`/`rawContent`/`summary`) stays unfetched.
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return try modelContext.fetch(descriptor).map(ArticleSummary.init)
    }
}

/// Single source of truth for the timeline/list dataset. Loads the whole library's lightweight
/// metadata once at launch (off-main) and keeps it in sync with every `ModelContext` save.
@MainActor
@Observable
final class ArticleStore {
    private(set) var summaries: [ArticleSummary] = []
    private(set) var hasLoaded = false

    private let container: ModelContainer
    private var observer: NSObjectProtocol?
    private var debounce: Task<Void, Never>?

    init(container: ModelContainer) { self.container = container }

    /// Begin observing saves and trigger the first load. Idempotent.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            // Hop to the main actor; coalesce bursts (e.g. an updateAll() run) into one refresh.
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        Task { await refreshNow() }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    /// Reload the index and publish it. Awaited directly by tests.
    func refreshNow() async {
        let loader = ArticleSummaryLoader(modelContainer: container)
        let loaded = (try? await loader.load()) ?? []
        summaries = loaded
        hasLoaded = true
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
```

- [ ] **Step 4: Regenerate + run the store tests**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStore
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift Yana.xcodeproj YanaTests/ArticleStoreTests.swift
git commit -m "feat(service): add ArticleStore with background loader and didSave sync"
```

---

### Task 3: Inject the store into the app and start it at launch

**Files:**
- Modify: `Yana/YanaApp.swift`
- Modify: `Yana/ContentView.swift`

**Interfaces:**
- Consumes: `ArticleStore(container:)`, `ArticleStore.start()` from Task 2.
- Produces: an `ArticleStore` in the SwiftUI environment (`@Environment(ArticleStore.self)`), started once. `ContentView` no longer owns a timeline limit.

- [ ] **Step 1: Add the store to the scene**

In `Yana/YanaApp.swift`, change the `YanaApp` struct to own and inject the store:

```swift
@main
struct YanaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var articleStore = ArticleStore(container: AppContainer.shared)

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .environment(articleStore)
                .task { articleStore.start() }
        }
        .modelContainer(AppContainer.shared)
    }
}
```

- [ ] **Step 2: Simplify `ContentView` (drop windowing plumbing)**

Replace the body of `Yana/ContentView.swift` with:

```swift
import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        ReaderScreen(appState: appState)
    }
}
```

(`ReaderScreen`'s new no-window initializer is delivered in Task 5; the project will not compile cleanly until Task 5 lands — these two file edits plus Task 5 form one compiling unit. Commit at the end of Task 5.)

- [ ] **Step 3: Build check is deferred to Task 5**

Do NOT build or commit yet — `ReaderScreen(appState:)` does not exist until Task 5. Proceed to Task 4.

---

### Task 4: Switch the reader pager to `ArticleSummary` + on-demand `Article` resolution

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift`

**Interfaces:**
- Consumes: `ArticleSummary` (Task 1), generic `TimelinePageIndex.index` (Task 1).
- Produces: `ReaderArticleViewController` now stores `[ArticleSummary]`; `configure(articles:index:)` and `update(articles:index:)` take `[ArticleSummary]`; new `var resolveArticle: ((ArticleSummary) -> Article?)?` is used by `makePage`. Callbacks (`onToggleStar`/`onForceUpdateArticle`/`onCopyLink`/`onSummarize`) still pass a resolved `Article`.

- [ ] **Step 1: Change the stored data type and current-article accessor**

In `Yana/Reader/ReaderArticleViewController.swift`:

Change the stored array (line ~25) from:
```swift
    private var articles: [Article] = []
```
to:
```swift
    private var articles: [ArticleSummary] = []
    /// Resolves a summary to its full `Article` (with HTML) on demand, set by the host.
    var resolveArticle: ((ArticleSummary) -> Article?)?
```

Replace `currentArticle()` (lines ~207-210):
```swift
    private func currentArticle() -> Article? {
        displayedWebVC?.article
    }
```

- [ ] **Step 2: Update `configure` / `update` signatures**

Change `configure(articles:index:)` signature to `func configure(articles: [ArticleSummary], index: Int)` (body unchanged otherwise).

Change `update(articles:index:)` signature to `func update(articles: [ArticleSummary], index: Int)`. Its body already compares `displayedWebVC?.article.identifier` against `articles[target].identifier` — `ArticleSummary` has `.identifier`, so it still compiles.

- [ ] **Step 3: Resolve the full article in `makePage`**

Replace `makePage(for:)` (lines ~212-225) with:

```swift
    private func makePage(for index: Int) -> ReaderWebViewController? {
        guard articles.indices.contains(index) else { return nil }
        let summary = articles[index]
        if let cached = pageCache.value(for: summary.identifier) { return cached }
        guard let article = resolveArticle?(summary) else { return nil }
        let vc = ReaderWebViewController(
            article: article,
            allowsFullscreen: isFullscreenAvailable,
            onRefresh: onRefresh,
            onRequestShowBars: { [weak self] in self?.applyFullscreen(false, animated: true) }
        )
        vc.hideBarsTapZonesActive(settings.articleFullscreenEnabled && isFullscreenAvailable)
        pageCache.insert(vc, for: summary.identifier)
        return vc
    }
```

- [ ] **Step 4: Fix the memory-warning trim (uses `articles[..].identifier`)**

`handleMemoryWarning()` already maps `articles[$0].identifier`; `ArticleSummary.identifier` keeps it valid — no change needed. Verify it still reads:
```swift
        let keep = Set(live.filter { articles.indices.contains($0) }.map { articles[$0].identifier })
```

The two `UIPageViewControllerDataSource` methods and `didFinishAnimating` resolve indices via `TimelinePageIndex.index(of: vc.article.identifier, in: articles)`. `vc.article` is a real `Article` (still `TimelineIdentifiable`); `articles` is `[ArticleSummary]` (also `TimelineIdentifiable`) — the generic `index(of:in:)` matches `vc.article.identifier` against summary identifiers. No change needed.

- [ ] **Step 5: No build yet**

This file references `Article` resolution wired in Task 5. Proceed to Task 5; build at the end of Task 5.

---

### Task 5: Reader host + screen consume the store (windowing removed)

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift`

**Interfaces:**
- Consumes: `ArticleStore` (Task 2), `[ArticleSummary]` pager API + `resolveArticle` (Task 4), generic `TagFilter`/`FeedFilter`/`TimelineAnchor`/`TimelinePageIndex` (Task 1), `TimelineLoadState.derive` (unchanged).
- Produces: `ReaderHostView` takes `articles: [ArticleSummary]` and `resolveArticle`. `ReaderScreen(appState:)` — no `limit`/`onNeedMore`. Reads `@Environment(ArticleStore.self)`. `openArticle(_:)` takes an `ArticleSummary`.

- [ ] **Step 1: Update `ReaderHostView` to carry summaries + a resolver**

In `Yana/Reader/ReaderHostView.swift`, change the representable's stored props:
```swift
    let articles: [ArticleSummary]
    /// Resolves a summary to its full `Article`; passed straight to the pager.
    let resolveArticle: (ArticleSummary) -> Article?
    @Binding var currentIndex: Int
```

In `makeUIViewController`, after `context.coordinator.reader = reader` add:
```swift
        reader.resolveArticle = resolveArticle
```
and in `updateUIViewController`, after `guard let reader = ...`, add the same line:
```swift
        reader.resolveArticle = resolveArticle
```
The existing `reader.configure(articles: articles, index: currentIndex)` and `reader.update(articles: articles, index: currentIndex)` now pass `[ArticleSummary]` — matches Task 4.

- [ ] **Step 2: Rework `ReaderScreen` to read the store and drop windowing**

Replace the `ReaderScreen` declaration through its `init` and `timelineDescriptor` (lines ~90-121) with:

```swift
struct ReaderScreen: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    init(appState: AppState) {
        self.appState = appState
    }
```

Delete the `@Query private var allArticles` line and the entire `static func timelineDescriptor` method. Keep `@Query(filter: ...) private var builtInTags`, `@State settings`, `didRestoreAnchor`, `toast`, `isSummarizing`, `reloadToken`, `filteredArticles`, `hasComputedFilter`. Delete `@State private var articleListLimit`.

Change `filteredArticles` type:
```swift
    @State private var filteredArticles: [ArticleSummary] = []
```

- [ ] **Step 3: Recompute from the store (no reverse, no windowing)**

Replace `recomputeFilter()` and delete `extendWindowIfNeeded()`:

```swift
    private func recomputeFilter() {
        // store.summaries is already chronological (oldest → new); filter in place.
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        filteredArticles = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        hasComputedFilter = store.hasLoaded
    }
```

- [ ] **Step 4: Update `body` — load state, host args, list sheet**

Change the load-state line to use the store:
```swift
            switch TimelineLoadState.derive(hasComputedFilter: store.hasLoaded, count: articles.count) {
```

Replace the `ReaderHostView(...)` call's first arguments to pass summaries + the resolver (everything from `currentIndex:` down is unchanged):
```swift
                ReaderHostView(
                    articles: articles,
                    resolveArticle: { modelContext.model(for: $0.persistentID) as? Article },
                    currentIndex: $appState.currentIndex,
                    onUserNavigate: { saveAnchor(at: $0) },
                    ...
```

In `onShowArticleList`, drop the `articleListLimit = ...` line; keep `appState.showArticleList = true`.

Replace the article-list sheet block:
```swift
        .sheet(isPresented: $appState.showArticleList) {
            NavigationStack {
                ArticleListView(
                    currentArticleID: filteredArticles.indices.contains(appState.currentIndex)
                        ? filteredArticles[appState.currentIndex].identifier : nil,
                    onSelect: openArticle
                )
            }
        }
```

- [ ] **Step 5: React to store changes; drop the window-extend onChange**

Replace the `.onChange(of: appState.currentIndex)` and `.onChange(of: allArticles)` handlers with:
```swift
        .onChange(of: store.summaries) { _, _ in
            recomputeFilter()
            if didRestoreAnchor { reanchorToCurrentArticle() } else { restoreAnchor() }
        }
```
Keep the three `settings.*` `.onChange` handlers and the `.onAppear { recomputeFilter(); restoreAnchor(); ... }`.

- [ ] **Step 6: Update `openArticle` to take a summary; fix anchor helper types**

Replace `openArticle`:
```swift
    private func openArticle(_ summary: ArticleSummary) {
        recomputeFilter()
        if let i = TimelinePageIndex.index(of: summary.identifier, in: filteredArticles) {
            appState.currentIndex = i
            settings.timelineAnchorIdentifier = summary.identifier
        }
        appState.showArticleList = false
    }
```

`restoreAnchor`, `saveAnchor`, `reanchorToCurrentArticle`, `clampIndex` operate on `filteredArticles` ([ArticleSummary]) and use `.identifier` / generic `TimelineAnchor` — they compile unchanged. `toggleStar`/`forceUpdateArticle`/`copyLink`/`summarize` still take `Article` (the reader passes the resolved live article) — unchanged.

- [ ] **Step 7: Build the whole app (Tasks 3–5 compile together)**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Run the timeline/reader-adjacent test suites**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:YanaTests/TimelineOrderingTests \
  -only-testing:YanaTests/TimelineFilteringTests \
  -only-testing:YanaTests/TimelineLoadStateTests
```
Expected: PASS.

- [ ] **Step 9: Commit (Tasks 3, 4, 5 together)**

```bash
git add Yana/YanaApp.swift Yana/ContentView.swift Yana/Reader/ReaderArticleViewController.swift Yana/Reader/ReaderHostView.swift Yana.xcodeproj
git commit -m "feat(reader): drive the reader from ArticleStore summaries; remove windowing"
```

---

### Task 6: Article list consumes the store; predicate-backed search; selection UI

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (ReaderScreen already passes `onSelect: openArticle` expecting `ArticleSummary` — done in Task 5)
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: `YanaTests/ArticleListSearchTests.swift`

**Interfaces:**
- Consumes: `ArticleStore` (Task 2), `ArticleSummary` (Task 1), generic filters (Task 1).
- Produces: `ArticleListView(currentArticleID:onSelect:)` where `onSelect: (ArticleSummary) -> Void`. New free function `ArticleListSearch.predicate(for:) -> Predicate<Article>` (testable).

- [ ] **Step 1: Write the failing search-predicate test**

Create `YanaTests/ArticleListSearchTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleListSearch")
struct ArticleListSearchTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func insert(_ context: ModelContext, id: String, title: String, content: String, author: String) {
        let a = Article(title: title, identifier: id, url: id, content: content, author: author)
        context.insert(a)
    }

    @Test func matchesTitleContentAndAuthorCaseInsensitively() throws {
        let context = try makeContext()
        insert(context, id: "1", title: "Swift Concurrency", content: "<p>actors</p>", author: "Ada")
        insert(context, id: "2", title: "Cooking", content: "<p>pasta and SWIFT sauce</p>", author: "Bo")
        insert(context, id: "3", title: "Gardening", content: "<p>soil</p>", author: "swiftly Cy")
        try context.save()

        let predicate = ArticleListSearch.predicate(for: "swift")
        let results = try context.fetch(FetchDescriptor<Article>(predicate: predicate))

        #expect(Set(results.map(\.identifier)) == ["1", "2", "3"])
    }

    @Test func nonMatchExcluded() throws {
        let context = try makeContext()
        insert(context, id: "1", title: "Swift", content: "x", author: "Ada")
        insert(context, id: "2", title: "Rust", content: "y", author: "Bo")
        try context.save()

        let results = try context.fetch(FetchDescriptor<Article>(predicate: ArticleListSearch.predicate(for: "rust")))
        #expect(results.map(\.identifier) == ["2"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleListSearch`
Expected: FAIL — `ArticleListSearch` undefined.

- [ ] **Step 3: Add the search predicate helper**

Add to the top of `Yana/Views/Config/ArticleListView.swift` (above the `struct ArticleListView`):

```swift
/// Builds the SwiftData predicate for the list's full-text search: title / content / author /
/// feed name, case- & diacritic-insensitive. SQLite performs the scan, so article HTML is never
/// loaded into memory en masse.
enum ArticleListSearch {
    static func predicate(for query: String) -> Predicate<Article> {
        let q = query
        return #Predicate<Article> { article in
            article.title.localizedStandardContains(q)
                || article.content.localizedStandardContains(q)
                || article.author.localizedStandardContains(q)
                || (article.feed?.name ?? "").localizedStandardContains(q)
        }
    }
}
```

- [ ] **Step 4: Rewrite `ArticleListView` to read the store**

Replace the `struct ArticleListView` declaration through its `init` and `timelineDescriptor` / `@Query allArticles` / `canLoadMore` / `loadMoreIfNeeded` with a store-backed version. The new top of the struct:

```swift
struct ArticleListView: View {
    let currentArticleID: String?
    let onSelect: (ArticleSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResults: [ArticleSummary]? = nil
    @State private var showFilter = false
    @State private var summaryToDelete: ArticleSummary?

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }
    private var isUpdating: Bool { UpdateActivity.shared.isUpdating }

    /// Browsing reads the in-memory index; a search swaps in predicate-fetched results. Both run
    /// through the shared tag/feed filter so the list stays a subset of the reader timeline.
    private var results: [ArticleSummary] {
        let base = searchResults ?? store.summaries
        let byTag = TagFilter.apply(to: base,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        return FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    private var isFilterActive: Bool { settings.isTimelineFilterActive }

    private func article(for summary: ArticleSummary) -> Article? {
        modelContext.model(for: summary.persistentID) as? Article
    }
```

- [ ] **Step 5: Update `body` — remove `canLoadMore`/`loadMoreIfNeeded`, add the search task, new row + selection**

Replace the `body` with:

```swift
    var body: some View {
        let results = results
        let currentItemID = results.first { $0.identifier == currentArticleID }?.id
        return ManagedList(
            items: results,
            searchText: $searchText,
            searchPrompt: "Search articles",
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "No articles yet. Add feeds, then pull to refresh.",
            onDelete: { offsets in
                guard let summary = offsets.map({ results[$0] }).first else { return }
                summaryToDelete = summary
            },
            scrollToID: currentItemID,
            leadingActions: { summary in
                Button {
                    guard let starredTag, let article = article(for: summary) else { return }
                    article.setStarred(!article.isStarred, using: starredTag)
                    try? modelContext.save()
                    Haptics.impact(.light)
                } label: {
                    Label(summary.isStarred ? "Unstar" : "Star",
                          systemImage: summary.isStarred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button {
                    guard let article = article(for: summary) else { return }
                    UpdateActivity.shared.restart {
                        await AggregationService(context: modelContext).forceReload(article: article)
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .tint(.orange)
            }
        ) { summary in
            Button { onSelect(summary) } label: { row(summary) }
                .buttonStyle(.plain)
                .listRowBackground(summary.identifier == currentArticleID
                                   ? Color.accentColor.opacity(0.15) : nil)
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        .task(id: debouncedSearch) { await runSearch() }
        .navigationTitle("Articles")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
            ToolbarItem(placement: .topBarLeading) {
                if isUpdating {
                    Button { UpdateActivity.shared.cancel() } label: { ProgressView() }
                        .accessibilityLabel(Text("Stop updating"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilter = true } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilter) { TagFilterView() }
        .confirmationDialog(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { summaryToDelete != nil }, set: { if !$0 { summaryToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let summary = summaryToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let article = article(for: summary) {
                        modelContext.delete(article)
                        try? modelContext.save()
                        Haptics.notify(.success)
                    }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let summary = summaryToDelete {
                Text(String(localized: "Delete \u{201C}\(summary.title)\u{201D}? This cannot be undone."))
            }
        }
    }

    /// Run the full-text predicate fetch while a query is active; clear back to the index otherwise.
    private func runSearch() async {
        let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = nil; return }
        var descriptor = FetchDescriptor<Article>(
            predicate: ArticleListSearch.predicate(for: q),
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        searchResults = matches.map(ArticleSummary.init)
    }
```

- [ ] **Step 6: Replace `row(_:)` with the summary row + selection chrome**

```swift
    private func row(_ summary: ArticleSummary) -> some View {
        let isCurrent = summary.identifier == currentArticleID
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.accentColor : Color.clear)
                .frame(width: 3)
            FeedLogoView(hash: summary.feedLogoHash)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if !summary.feedName.isEmpty {
                        Text(summary.feedName)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(summary.date, style: .date)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            if isCurrent {
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(Text("Current article"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
```

- [ ] **Step 7: Add the German translation**

Add to `Yana/Resources/Localizable.xcstrings` a `"Current article"` key with a `de` translation. The JSON entry under `"strings"`:

```json
    "Current article" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Aktueller Artikel"
          }
        }
      }
    },
```

(Insert in alphabetical position among existing keys; keep file valid JSON.)

- [ ] **Step 8: Build + run the search test + existing list filter tests**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:YanaTests/ArticleListSearch \
  -only-testing:YanaTests/ArticleListFilterTests \
  -only-testing:YanaTests/ArticleListFilteringTests
```
Expected: BUILD SUCCEEDED; tests PASS. If `ArticleListFilterTests`/`ArticleListFilteringTests` reference the old `[Article]` query shape, update them to the generic filter API (they call `TagFilter`/`FeedFilter`, which still accept `[Article]`).

- [ ] **Step 9: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift Yana/Resources/Localizable.xcstrings YanaTests/ArticleListSearchTests.swift Yana.xcodeproj
git commit -m "feat(list): drive list from ArticleStore; predicate search; clearer selection"
```

---

### Task 7: Remove the dead `TimelineWindow` system

**Files:**
- Delete: `Yana/Utilities/TimelineWindow.swift`
- Delete: `YanaTests/TimelineWindowTests.swift`
- Verify: no remaining references.

**Interfaces:**
- Consumes: nothing. This is cleanup after Tasks 5–6 removed all usages.

- [ ] **Step 1: Confirm there are no live references**

Run:
```bash
grep -rn "TimelineWindow" Yana YanaTests
```
Expected: matches only in `Yana/Utilities/TimelineWindow.swift` and `YanaTests/TimelineWindowTests.swift`. If any other file references it, STOP — a prior task left a usage; fix that first.

- [ ] **Step 2: Delete the files and regenerate**

```bash
git rm Yana/Utilities/TimelineWindow.swift YanaTests/TimelineWindowTests.swift
xcodegen generate
```

- [ ] **Step 3: Full build + full test run**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: BUILD SUCCEEDED; entire suite PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove unused TimelineWindow after store migration"
```

---

### Task 8: Update project docs

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: Update the architecture notes**

In `CLAUDE.md`, update the Services and Key patterns sections to describe `ArticleStore` (background-loaded, `didSave`-synced lightweight `ArticleSummary` index consumed by both the reader and the list) and remove the windowing description ("window the newest page", `TimelineWindow`). Keep the edit tight — one sentence in Services for the store, and replace the windowing sentence in "Update vs. reload"/timeline notes with the store-backed behavior.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe ArticleStore and drop windowing notes"
```

---

## Self-Review

**Spec coverage:**
- `ArticleSummary` + store + background loader + `didSave` sync → Tasks 1–2. ✓
- Upfront/background load + environment injection → Tasks 2–3. ✓
- Reader consumes summaries, lazy full-article resolution → Tasks 4–5. ✓
- List consumes store, instant open, predicate search → Task 6. ✓
- Windowing removed → Tasks 5 (usage) + 7 (deletion). ✓
- Selection UI (accent bar + checkmark) + `de` localization → Task 6. ✓
- Tests for mapping/sync/filter/search → Tasks 1, 2, 6. ✓
- Docs → Task 8. ✓

**Placeholder scan:** No TBD/TODO; every code step has concrete code.

**Type consistency:** `ArticleSummary` fields used identically across tasks; pager API `configure/update(articles: [ArticleSummary])` + `resolveArticle: (ArticleSummary) -> Article?` consistent between Tasks 4 and 5; `onSelect: (ArticleSummary) -> Void` consistent between Tasks 5 and 6; `ArticleListSearch.predicate(for:)` consistent between Tasks 6 test and impl.

**Compile-unit note:** Tasks 3–5 change shared signatures and only compile together; they share a single build/commit at the end of Task 5. This is called out explicitly in Tasks 3 and 4.
