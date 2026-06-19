# Performance Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the verified performance bottlenecks in feed aggregation and the reader/list UI without changing any user-visible behavior.

**Architecture:** Seven independent tasks, ordered by impact. Tasks 1 and 7 are pure-logic changes covered by unit tests (Swift Testing). Tasks 2–6 are SwiftUI/SwiftData changes verified by a clean build plus the existing test suite, since they touch view state and `@Query` configuration that the unit harness does not exercise.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- **Platform:** iOS 26.0+ (iPhone and iPad).
- **Swift 6 strict concurrency:** all view/model code stays `@MainActor`; types crossing task boundaries must be `Sendable`.
- **No behavior change:** every task must preserve current observable behavior (article order, drop-on-AI-failure semantics, search/filter results, retention). These are refactors for speed, not feature changes.
- **Build command:** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- **Test command:** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- **No new user-facing strings.** None of these tasks add UI text, so no `Localizable.xcstrings` changes are required. If any task ends up adding a string, it MUST be added to `Localizable.xcstrings` with a `de` translation marked `"state" : "translated"`.
- Commit after every task with a `perf:` prefix.

### Investigated and intentionally NOT included

- **"Batch the retention deletes":** rejected. `RetentionCleanup.run` already marks every delete and `AggregationService.cleanupAndSave()` calls `context.save()` exactly once afterward ([AggregationService.swift:335](Yana/Services/AggregationService.swift:335)), so the deletes are already coalesced into a single transaction. No change needed.
- **"Window the timeline `@Query` with a fetch limit":** rejected for now. The home surface is an *endless* timeline the user swipes through in both directions; a fetch limit would require incremental paging in `ReaderArticleViewController`'s data source — a large architectural change. Task 2 (memoization) + Task 3 (relationship prefetch) capture the bulk of the available win at a fraction of the risk.

---

### Task 1: Concurrent AI post-processing

**Problem:** [AIProcessor.swift:42-70](Yana/Services/AIProcessor.swift:42) processes articles in a serial `for` loop — each `await generate(...)` (2–5 s) blocks the next, and a `requestDelay` sleep (default 2 s) is inserted between every article. A feed with 15 articles spends 30–100 s in AI alone, collapsing the 5-way feed parallelism. Fix: overlap the network waits with a bounded `TaskGroup` while still *spacing out request launches* by `requestDelay` (preserving the rate-limit intent), and preserve output order and drop-on-failure semantics exactly.

**Files:**
- Modify: `Yana/Services/AIProcessor.swift` (the `process(_:ai:)` method body, lines 35–71)
- Test: `YanaTests/AIProcessorTests.swift` (add cases)

**Interfaces:**
- Consumes: `AggregatedArticle`, `AIOptions`, the existing `generate: Generate` closure, `Self.buildPrompt`, `Self.extractJSON`, `ArticleAIText.cap`, `ArticleAIText.stripChrome`.
- Produces: unchanged public signature `func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle]`. New private members: `static let maxConcurrentAIRequests = 3` and `func processOne(_ article: AggregatedArticle, ai: AIOptions) async -> AggregatedArticle?` (returns the article unchanged for empty content, the AI-updated article on success, or `nil` to DROP on invalid JSON / failure).

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/AIProcessorTests.swift`. The first asserts requests overlap (peak concurrency > 1); the second asserts order is preserved and a failing article is dropped.

```swift
import Testing
@testable import Yana

/// Tracks how many `generate` calls are in flight at once.
private actor ConcurrencyProbe {
    private(set) var peak = 0
    private var current = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@MainActor
@Test func aiProcessorOverlapsRequests() async {
    let probe = ConcurrencyProbe()
    let processor = AIProcessor(config: .testEnabled, requestDelay: 0) { prompt, _ in
        await probe.enter()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — long enough to overlap
        await probe.leave()
        return #"{"title":"t","content":"c"}"#
    }
    let input = (0..<6).map { AggregatedArticle.fixture(identifier: "\($0)", content: "body") }
    _ = await processor.process(input, ai: .summarizeOnly)
    #expect(await probe.peak > 1)
    #expect(await probe.peak <= AIProcessor.maxConcurrentAIRequests)
}

@MainActor
@Test func aiProcessorPreservesOrderAndDropsFailures() async {
    let processor = AIProcessor(config: .testEnabled, requestDelay: 0) { prompt, _ in
        // The second article (content "DROP") returns junk → dropped.
        if prompt.contains("DROP") { return "not json" }
        return #"{"title":"ok","content":"c"}"#
    }
    let input = [
        AggregatedArticle.fixture(identifier: "a", content: "keep1"),
        AggregatedArticle.fixture(identifier: "b", content: "DROP"),
        AggregatedArticle.fixture(identifier: "c", content: "keep2"),
    ]
    let out = await processor.process(input, ai: .summarizeOnly)
    #expect(out.map(\.identifier) == ["a", "c"]) // order preserved, "b" dropped
}
```

> **Before running:** check `YanaTests/AIProcessorTests.swift` for the existing test helpers. If `AIConfig.testEnabled`, `AggregatedArticle.fixture(identifier:content:)`, or `AIOptions.summarizeOnly` do not already exist there or in `TestHelper.swift`, reuse whatever the existing tests in that file use to build a processor with an enabled config and a fixture article (the file already constructs `AIProcessor` with an injected generator). Match the existing fixtures rather than inventing new ones.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests 2>&1 | tail -30`
Expected: FAIL — `aiProcessorOverlapsRequests` fails because the current serial loop never overlaps (peak == 1).

- [ ] **Step 3: Add the concurrency constant and the per-article helper**

In `AIProcessor`, add the constant near the stored properties:

```swift
    /// Upper bound on simultaneous in-flight AI requests. Caps overlap so a large batch does
    /// not fan out to unbounded concurrent provider calls.
    static let maxConcurrentAIRequests = 3
```

Add the helper (place it just after `process(_:ai:)`):

```swift
    /// Process a single article. Returns it unchanged when content is empty (server parity),
    /// the AI-updated article on success, or `nil` to DROP it (invalid JSON or AI failure).
    private func processOne(_ article: AggregatedArticle, ai: AIOptions) async -> AggregatedArticle? {
        guard !article.content.isEmpty else { return article }
        let cleanHTML = ArticleAIText.cap((try? ArticleAIText.stripChrome(article.content)) ?? article.content)
        let prompt = Self.buildPrompt(title: article.title, cleanHTML: cleanHTML, ai: ai)
        do {
            let raw = try await generate(prompt, true)
            guard let parsed = Self.extractJSON(raw) else { return nil }
            var updated = article
            if let title = parsed["title"] as? String { updated.title = title }
            if let content = parsed["content"] as? String { updated.content = content }
            if let summary = parsed["summary"] as? String { updated.summary = summary }
            return updated
        } catch {
            return nil
        }
    }
```

- [ ] **Step 4: Replace the serial loop with a bounded, order-preserving task group**

Replace the body of `process(_:ai:)` from line 42 (`var output: [AggregatedArticle] = []`) through the `return output` at line 70 with:

```swift
        // Results indexed by input position so order is preserved regardless of completion order.
        var results = [AggregatedArticle?](repeating: nil, count: input.count)
        let cap = min(Self.maxConcurrentAIRequests, input.count)

        await withTaskGroup(of: (Int, AggregatedArticle?).self) { group in
            var launched = 0

            // Launch one article's request, spacing launches by `requestDelay` to respect
            // provider rate limits (the responses still overlap).
            func launch(_ i: Int) async {
                if i > 0, requestDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000_000)
                }
                let article = input[i]
                group.addTask { (i, await self.processOne(article, ai: ai)) }
            }

            while launched < cap, !Task.isCancelled {
                await launch(launched)
                launched += 1
            }

            while let (index, value) = await group.next() {
                results[index] = value
                if Task.isCancelled { break }   // a newer run cancelled this one — stop launching
                if launched < input.count {
                    await launch(launched)
                    launched += 1
                }
            }
        }

        return results.compactMap { $0 }
```

Keep the gate block above it (lines 35–40) unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests 2>&1 | tail -30`
Expected: PASS — including the pre-existing `AIProcessorTests` and `AIProcessorSummaryTests` cases (order/drop semantics unchanged).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AIProcessor.swift YanaTests/AIProcessorTests.swift
git commit -m "perf(ai): process articles concurrently with bounded overlap"
```

---

### Task 2: Memoize the timeline tag filter

**Problem:** [ReaderHostView.swift:63-69](Yana/Reader/ReaderHostView.swift:63) computes `filteredArticles` as a computed property, and `body` reads it on every evaluation ([:74](Yana/Reader/ReaderHostView.swift:74)). Because `currentIndex` is a `@Binding` that updates on **every page swipe**, `TagFilter.apply` re-runs over the entire article set on every swipe. Fix: cache the filtered array in `@State` and recompute only when the inputs (the query result or the filter settings) actually change.

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift` (the `ReaderScreen` struct, lines 53–90+)

**Interfaces:**
- Consumes: `TagFilter.apply(to:disabledTagNames:includeUntagged:)` (unchanged, pure), `allArticles` (`@Query`), `settings.disabledTagNames`, `settings.includeUntagged`.
- Produces: a `@State private var filteredArticles: [Article]` cache and a `private func recomputeFilter()`; `body` reads the cached array instead of recomputing.

- [ ] **Step 1: Replace the computed property with a cached state value + recompute function**

In `ReaderScreen`, delete the computed property:

```swift
    private var filteredArticles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }
```

and replace it with a stored cache plus a recompute helper:

```swift
    @State private var filteredArticles: [Article] = []

    private func recomputeFilter() {
        filteredArticles = TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }
```

- [ ] **Step 2: Read the cached value in `body` and wire up recompute triggers**

In `body`, keep `let articles = filteredArticles` (now reading the cached `@State`). Attach recompute modifiers to the outer `Group`. Add these to the `Group { ... }` in `body` (alongside the existing modifiers):

```swift
        .onAppear { recomputeFilter() }
        .onChange(of: allArticles) { _, _ in recomputeFilter() }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeFilter() }
```

This recomputes when the timeline contents change or the user changes the tag filter — but NOT when `currentIndex` changes during a swipe.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. (`[Article]` is `Equatable` by identity via `PersistentModel`, so `onChange(of: allArticles)` compiles; `Set<String>` and `Bool` are `Equatable`.)

- [ ] **Step 4: Run the full test suite (no regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -20`
Expected: all tests PASS.

- [ ] **Step 5: Manual verification**

Run the app (Yana scheme), add a feed, refresh so the timeline has articles, then swipe through several articles. Confirm the timeline still shows the same filtered set and that toggling a tag in the Filter sheet still updates the timeline immediately.

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift
git commit -m "perf(reader): memoize timeline tag filter so swiping doesn't refilter"
```

---

### Task 3: Prefetch `feed` and `tags` relationships in the timeline queries

**Problem:** The reader pre-loads adjacent pages; each page's `ArticleRenderer` reads `article.feed?.logoHash` and `article.feed?.name` ([ArticleRenderer.swift:49,56](Yana/Reader/ArticleRenderer.swift:49)), and `TagFilter` reads `article.tags`. With a plain `@Query`, those to-one/to-many relationships fault in lazily — one round-trip per article (N+1). Fix: tell SwiftData to batch-fetch `\.feed` and `\.tags` alongside the articles via `relationshipKeyPathsForPrefetching`.

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift` (the `@Query` at line 57 in `ReaderScreen`)
- Modify: `Yana/Views/Config/ArticleListView.swift` (the `@Query` at line 10)

**Interfaces:**
- Produces: a `static var timelineDescriptor: FetchDescriptor<Article>` on each view, used to initialize the existing `allArticles` query. No call-site changes elsewhere.

- [ ] **Step 1: Add a prefetching descriptor and use it in `ReaderScreen`**

In `ReaderScreen`, replace:

```swift
    @Query(sort: \Article.createdAt, order: .reverse) private var allArticles: [Article]
```

with:

```swift
    @Query(ReaderScreen.timelineDescriptor) private var allArticles: [Article]

    static var timelineDescriptor: FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Batch-load the relationships every page render touches, avoiding N+1 faulting.
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return descriptor
    }
```

- [ ] **Step 2: Apply the same prefetch to `ArticleListView`**

In `ArticleListView`, replace:

```swift
    @Query(sort: \Article.createdAt, order: .reverse) private var allArticles: [Article]
```

with:

```swift
    @Query(ArticleListView.timelineDescriptor) private var allArticles: [Article]

    static var timelineDescriptor: FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return descriptor
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite (no regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -20`
Expected: all tests PASS — the query still returns the same articles in the same order.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift Yana/Views/Config/ArticleListView.swift
git commit -m "perf(swiftdata): prefetch feed and tags relationships in timeline queries"
```

---

### Task 4: Debounce the article-list search

**Problem:** [ArticleListView.swift:24-27](Yana/Views/Config/ArticleListView.swift:24) recomputes `results` — which runs `ArticleSearch.filter` over every article's full HTML `content` ([ArticleSearch.swift:11](Yana/Aggregators/ArticleSearch.swift:11)) — on **every keystroke**, on the main thread. Fix: debounce the query so filtering runs ~250 ms after typing stops, preserving the existing full-content search feature while keeping the field responsive.

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`

**Interfaces:**
- Produces: a `@State private var debouncedSearch = ""` driving `results`; `searchText` continues to back the search field.

- [ ] **Step 1: Add a debounced state value and feed it into `results`**

In `ArticleListView`, add below `@State private var searchText = ""` (line 12):

```swift
    @State private var debouncedSearch = ""
```

Change `results` (line 24) to use the debounced value:

```swift
    private var results: [Article] {
        let searched = ArticleSearch.filter(allArticles, query: debouncedSearch)
        return TagFilter.apply(to: searched, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged)
    }
```

- [ ] **Step 2: Drive the debounce with a cancelling `.task(id:)`**

Add this modifier to the `ManagedList` in `body` (alongside `.navigationTitle("Articles")`):

```swift
        .task(id: searchText) {
            // Coalesce keystrokes: a new keystroke cancels this task and restarts the timer.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite (no regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -20`
Expected: all tests PASS (`ArticleSearch` logic is unchanged).

- [ ] **Step 5: Manual verification**

Run the app, open Library → Articles, type a query quickly. Confirm results appear shortly after you stop typing and match the same set as before (title/content/author/feed-name search still works).

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift
git commit -m "perf(search): debounce article-list search to avoid per-keystroke full-content scan"
```

---

### Task 5: Replace `feed.articles.count` in the feeds list with a batched count

**Problem:** [FeedsView.swift:166](Yana/Views/Config/FeedsView.swift:166) renders `feed.articles.count` inside each row, materializing each feed's entire `articles` relationship just to count it — once per visible row, re-faulted on list updates. Fix: compute counts once via cheap `fetchCount` queries cached in view state, keyed by feed id, refreshed when the feed set changes. (The identical `feed.articles.count` on the delete-confirmation dialog at [:129](Yana/Views/Config/FeedsView.swift:129) is left as-is — it's a single feed in a rare modal.)

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`

**Interfaces:**
- Produces: `@State private var articleCounts: [PersistentIdentifier: Int]` and `private func refreshArticleCounts()`; the row reads `articleCounts[feed.persistentModelID] ?? 0`.

- [ ] **Step 1: Add the count cache and a refresh function**

In `FeedsView`, add after `@State private var settings = AppSettings()` (line 16):

```swift
    @State private var articleCounts: [PersistentIdentifier: Int] = [:]

    private func refreshArticleCounts() {
        var counts: [PersistentIdentifier: Int] = [:]
        for feed in feeds {
            let id = feed.persistentModelID
            let descriptor = FetchDescriptor<Article>(
                predicate: #Predicate { $0.feed?.persistentModelID == id }
            )
            counts[id] = (try? modelContext.fetchCount(descriptor)) ?? 0
        }
        articleCounts = counts
    }
```

- [ ] **Step 2: Refresh the cache when the feed set changes**

Add to the `ManagedList` modifiers in `body` (alongside `.navigationTitle("Feeds")`):

```swift
        .onAppear { refreshArticleCounts() }
        .onChange(of: feeds) { _, _ in refreshArticleCounts() }
```

- [ ] **Step 3: Read the cached count in the row**

In `row(_ feed:)`, replace line 166:

```swift
                Text("\(feed.articles.count) articles")
```

with:

```swift
                Text("\(articleCounts[feed.persistentModelID] ?? 0) articles")
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite (no regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -20`
Expected: all tests PASS.

- [ ] **Step 6: Manual verification**

Run the app, open Library → Feeds with at least one feed that has articles. Confirm each row shows the correct article count, and that the count updates after a refresh adds articles.

- [ ] **Step 7: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "perf(feeds): count articles via fetchCount instead of materializing the relationship"
```

---

### Task 6: Cache favicon lookups by site

**Problem:** During a multi-feed update, new feeds (those with `logoHash == nil`) resolve their logo via `FaviconResolver.bestIconURL(forSite:)`, which fetches and parses the site's HTML. Feeds sharing a domain re-fetch the same favicon. Fix: add a process-wide in-memory cache keyed by the site string so each domain is resolved at most once per app run.

**Files:**
- Modify: `Yana/Aggregators/FaviconResolver.swift` (the `bestIconURL(forSite:)` async entry point)

**Interfaces:**
- Consumes: the existing `bestIconURL(forSite:)` network/parse path (renamed to an `uncached` helper).
- Produces: an `actor FaviconCache` and a memoizing `bestIconURL(forSite:)` that delegates to it. Public signature of `bestIconURL(forSite:)` is unchanged.

- [ ] **Step 1: Read the current `bestIconURL(forSite:)` implementation**

Open `Yana/Aggregators/FaviconResolver.swift` and locate the `static func bestIconURL(forSite siteURL: String, ...) async -> String?` method (the one that fetches HTML and falls back to `/favicon.ico`). Note its exact signature and any injectable parameters before editing.

- [ ] **Step 2: Add the cache actor and memoize the entry point**

Add a cache actor at the bottom of the file (inside the file, outside the `enum`):

```swift
/// Process-wide memo of resolved favicon URLs, keyed by the site string. Favicons are stable
/// for an app session, so caching avoids re-fetching the same domain across feeds in one update.
actor FaviconCache {
    static let shared = FaviconCache()
    private var entries: [String: String?] = [:]

    /// Returns the cached result, or computes and stores it on a miss.
    func value(for site: String, compute: () async -> String?) async -> String? {
        if let cached = entries[site] { return cached }
        let resolved = await compute()
        entries[site] = resolved
        return resolved
    }
}
```

Then wrap the existing fetch path. Rename the current `bestIconURL(forSite:)` method body to a private `uncachedBestIconURL(forSite:)` (keep its parameters and logic identical), and add a thin caching front door with the original signature:

```swift
    static func bestIconURL(forSite siteURL: String) async -> String? {
        await FaviconCache.shared.value(for: siteURL) {
            await uncachedBestIconURL(forSite: siteURL)
        }
    }
```

> Match the original parameter list exactly. If `bestIconURL(forSite:)` currently takes extra injectable parameters (e.g. a fetcher closure), keep them on `uncachedBestIconURL` and key the cache on `siteURL` only.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. (`FeedLogoResolver` calls `FaviconResolver.bestIconURL(forSite:)` through an injected closure default at [FeedLogoResolver.swift:12](Yana/Aggregators/FeedLogoResolver.swift:12) — that call site is unchanged.)

- [ ] **Step 4: Run the full test suite (no regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -20`
Expected: all tests PASS. (`FeedLogoResolver` tests inject their own `faviconResolver`, so they bypass the cache and stay deterministic.)

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/FaviconResolver.swift
git commit -m "perf(favicon): cache favicon lookups by site to dedupe network during updates"
```

---

### Task 7: Hoist the fenced-JSON regex to a static constant

**Problem:** [AIProcessor.swift:143-145](Yana/Services/AIProcessor.swift:143) compiles the same `NSRegularExpression` on every `firstFencedJSON(in:)` call — i.e. once per AI-processed article. Fix: compile it once as a static constant.

**Files:**
- Modify: `Yana/Services/AIProcessor.swift` (`firstFencedJSON(in:)`, lines 142–151)
- Test: `YanaTests/AIProcessorTests.swift` (a behavior-preservation test; only add if `extractJSON`/fenced-JSON extraction is not already covered)

**Interfaces:**
- Produces: `private static let fencedJSONRegex: NSRegularExpression?`; `firstFencedJSON(in:)` uses it. Behavior unchanged.

- [ ] **Step 1: Write a behavior-preservation test (skip if already covered)**

Check `YanaTests/AIProcessorTests.swift` for existing coverage of fenced-JSON extraction (it drives `process` with responses wrapped in ```` ```json ```` fences). If none exists, add:

```swift
@MainActor
@Test func aiProcessorExtractsFencedJSON() async {
    let processor = AIProcessor(config: .testEnabled, requestDelay: 0) { _, _ in
        "Here you go:\n```json\n{\"title\":\"T\",\"content\":\"C\"}\n```\nDone."
    }
    let out = await processor.process(
        [AggregatedArticle.fixture(identifier: "a", content: "body")],
        ai: .summarizeOnly
    )
    #expect(out.first?.title == "T")
    #expect(out.first?.content == "C")
}
```

- [ ] **Step 2: Run it to verify it passes against the current code**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests 2>&1 | tail -20`
Expected: PASS (this guards behavior; the refactor must keep it passing).

- [ ] **Step 3: Hoist the regex**

Add the static constant near the other private statics in `AIProcessor`:

```swift
    /// Compiled once: ```` ```(?:json)?\s*(\{.*?\})\s*``` ```` (DOTALL via `[\s\S]`).
    private static let fencedJSONRegex = try? NSRegularExpression(
        pattern: "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```"
    )
```

Replace the body of `firstFencedJSON(in:)` (lines 143–150) with:

```swift
    private static func firstFencedJSON(in raw: String) -> String? {
        guard let regex = fencedJSONRegex else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: raw)
        else { return nil }
        return String(raw[captured])
    }
```

- [ ] **Step 4: Run the tests to verify they still pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AIProcessor.swift YanaTests/AIProcessorTests.swift
git commit -m "perf(ai): compile fenced-JSON regex once"
```

---

## Final verification

- [ ] Run the full suite once more end-to-end:

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`.

- [ ] Confirm `git log --oneline` shows the seven `perf:` commits.
