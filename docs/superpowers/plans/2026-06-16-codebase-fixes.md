# Codebase Lints, Errors & Performance Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the correctness bugs, crash risks, security gaps, performance hotspots, and lint violations found in the Yana iOS codebase, leaving the build clean and `swiftlint lint` at zero.

**Architecture:** Three sequential phases, each independently shippable and ending green (build + tests + lint). Phase 1 fixes things that crash, lose data, leak secrets, or exhaust memory. Phase 2 removes O(n²)/N+1 hotspots and per-render/per-call waste. Phase 3 clears all SwiftLint findings and closes low-risk hardening gaps. Within a phase, tasks are independent and may be parallelized.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, SwiftSoup, Swift Testing (`import Testing`), XcodeGen, SwiftLint.

**Conventions for every task:**
- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- Lint: `swiftlint lint --quiet`
- New test files must be added to the `YanaTests` target — they are picked up automatically by the glob in `project.yml`, but run `xcodegen generate` if a new file is not compiled.
- Commit after each task with the message shown in its final step.

---

## Phase 1 — Correctness, crashes & security

### Task 1: Remove `try!` + force-unwrap fallback in MeinMmoAggregator

**Files:**
- Modify: `Yana/Aggregators/Concrete/MeinMmoAggregator.swift:215-217`

The fallback meant to be the *safe* path uses `try!` + `!`, which SwiftLint flags as an error and is a latent crash.

- [ ] **Step 1: Read the current `parse(_:)` helper**

Confirm lines 215-217 read:

```swift
private func parse(_ html: String) -> Element {
    (try? SwiftSoup.parseBodyFragment(html).body()?.child(0)) ?? (try! SwiftSoup.parse("<span></span>").body()!.child(0))
}
```

- [ ] **Step 2: Replace with a non-throwing fallback**

```swift
private func parse(_ html: String) -> Element {
    if let parsed = try? SwiftSoup.parseBodyFragment(html).body()?.child(0) {
        return parsed
    }
    // Detached empty element — never throws, never force-unwraps.
    return Element(Tag.valueOf("span"), "")
}
```

Note: `Tag` here is `SwiftSoup.Tag`. If the symbol collides with the app's `Tag` model in this file's scope, qualify it as `SwiftSoup.Tag.valueOf("span")`.

- [ ] **Step 3: Verify the force_try lint error is gone**

Run: `swiftlint lint --quiet --path Yana/Aggregators/Concrete/MeinMmoAggregator.swift`
Expected: no `force_try` violation (line-length violations are addressed in Phase 3).

- [ ] **Step 4: Build**

Run the build command.
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/MeinMmoAggregator.swift
git commit -m "fix: remove force-try crash path in MeinMmo parse fallback"
```

---

### Task 2: Cap HTTP response size in HTTPClient

**Files:**
- Modify: `Yana/Aggregators/Utils/HTTPClient.swift`
- Test: `YanaTests/HTTPClientTests.swift` (create)

`URLSession.data(for:)` buffers unbounded bodies. Stream with a byte cap so an oversized untrusted response aborts instead of exhausting memory.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/HTTPClientTests.swift`:

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct HTTPClientTests {
    @Test func enforcesMaxBytesGuard() {
        // The pure guard rejects a body that exceeds the cap.
        #expect(HTTPClient.exceedsCap(received: 11, cap: 10) == true)
        #expect(HTTPClient.exceedsCap(received: 10, cap: 10) == false)
        #expect(HTTPClient.exceedsCap(received: 0, cap: 10) == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HTTPClientTests`
Expected: FAIL — `exceedsCap` does not exist.

- [ ] **Step 3: Add the cap and the streaming read**

Add to `HTTPClient` (near the top, after `userAgent`):

```swift
/// Hard ceiling on a single response body. Untrusted feeds/images must not exhaust memory.
static let maxResponseBytes = 25 * 1024 * 1024   // 25 MB

/// Pure helper (unit-testable): true when the accumulated byte count exceeds the cap.
static func exceedsCap(received: Int, cap: Int) -> Bool { received > cap }
```

Replace the `send(_:maxAttempts:)` body's success branch so the body is streamed with a guard. Change the line:

```swift
let (data, response) = try await URLSession.shared.data(for: request)
```

to:

```swift
let (bytes, response) = try await URLSession.shared.bytes(for: request)
var data = Data()
for try await byte in bytes {
    data.append(byte)
    if exceedsCap(received: data.count, cap: maxResponseBytes) {
        throw AggregatorError.contentFetch("response exceeded \(maxResponseBytes) bytes")
    }
}
```

The rest of `send` (status-code handling, `contentType`, return) is unchanged — it already operates on `data` and `response`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HTTPClientTests`
Expected: PASS.

- [ ] **Step 5: Build + full suite**

Run the build then the test command.
Expected: build succeeds; existing aggregator tests still pass (they inject their own fetch closures and do not hit `send`).

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Utils/HTTPClient.swift YanaTests/HTTPClientTests.swift
git commit -m "fix: cap HTTP response body size to prevent memory exhaustion"
```

---

### Task 3: Truncate AI prompt input to a character budget

**Files:**
- Modify: `Yana/Services/AIProcessor.swift`
- Test: `YanaTests/AIProcessorTests.swift` (add a test; create the file if absent)

The cleaned HTML is sent to the LLM with no size cap. Cap it before building the prompt so large articles don't blow past `maxTokens` or produce huge payloads.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/AIProcessorTests.swift` (create the file with this content if it does not exist; otherwise append the test):

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct AIProcessorTests {
    @Test func truncatesOversizedContent() {
        let long = String(repeating: "a", count: AIProcessor.maxContentChars + 500)
        let capped = AIProcessor.cap(long)
        #expect(capped.count == AIProcessor.maxContentChars)
    }

    @Test func leavesSmallContentUnchanged() {
        let short = "short body"
        #expect(AIProcessor.cap(short) == short)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests`
Expected: FAIL — `maxContentChars` / `cap` do not exist.

- [ ] **Step 3: Add the cap and apply it**

Add to `AIProcessor` (static members, near `stripChrome`):

```swift
/// Upper bound on characters of article HTML sent to the LLM. Keeps the request payload
/// bounded regardless of source article size.
static let maxContentChars = 50_000

/// Truncate to the budget (no-op when already within it).
static func cap(_ html: String) -> String {
    html.count <= maxContentChars ? html : String(html.prefix(maxContentChars))
}
```

In `process(_:ai:)`, change the line:

```swift
let cleanHTML = (try? Self.stripChrome(article.content)) ?? article.content
```

to:

```swift
let cleanHTML = Self.cap((try? Self.stripChrome(article.content)) ?? article.content)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AIProcessor.swift YanaTests/AIProcessorTests.swift
git commit -m "fix: cap AI prompt content size to bound request payload"
```

---

### Task 4: Send the Gemini API key as a header, not a URL query param

**Files:**
- Modify: `Yana/Services/AIClient.swift:112-138`

The key is interpolated raw into the URL query string (unencoded, and lands in URL logs). Move it to the `x-goog-api-key` header.

- [ ] **Step 1: Replace `geminiRequest` URL + headers**

Change the URL construction and the final `jsonRequest` call in `geminiRequest`:

```swift
private func geminiRequest(prompt: String, jsonMode: Bool) throws -> URLRequest {
    let model = config.model
    guard let url = URL(string:
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
    else { throw AIClientError.invalidResponseShape }

    var generationConfig: [String: Any] = [
        "temperature": config.temperature,
        "maxOutputTokens": config.maxTokens,
    ]
    if jsonMode {
        generationConfig["responseMimeType"] = "application/json"
        generationConfig["responseSchema"] = [
            "type": "OBJECT",
            "properties": [
                "title": ["type": "STRING"],
                "content": ["type": "STRING"],
            ],
            "required": ["title", "content"],
        ]
    }
    let body: [String: Any] = [
        "contents": [["parts": [["text": prompt]]]],
        "generationConfig": generationConfig,
    ]
    return try jsonRequest(url: url, headers: ["x-goog-api-key": config.apiKey], body: body)
}
```

The `let key = config.apiKey` line and the `?key=\(key)` query are removed.

- [ ] **Step 2: Build**

Run the build command.
Expected: build succeeds.

- [ ] **Step 3: Run AIClient tests if present**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: PASS (any test asserting the Gemini URL must now check the header instead — update it if it fails on the removed query param).

- [ ] **Step 4: Commit**

```bash
git add Yana/Services/AIClient.swift
git commit -m "fix: pass Gemini API key via header instead of URL query"
```

---

### Task 5: Percent-encode Reddit URL components, drop force-unwraps, expire the token

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditClient.swift`
- Test: `YanaTests/RedditClientTests.swift` (add tests)

`subreddit`, `sort`, and `postID` are interpolated raw into URLs and force-unwrapped; the cached token never expires (~1h Reddit TTL).

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/RedditClientTests.swift`:

```swift
@Test func encodesPathComponents() {
    #expect(RedditClient.encodePath("all") == "all")
    #expect(RedditClient.encodePath("a b") == "a%20b")
    #expect(RedditClient.encodePath("a/b") == "a%2Fb")
}

@Test func tokenExpiryGate() {
    let now = Date(timeIntervalSince1970: 1_000)
    // Not expired when expiry is in the future.
    #expect(RedditClient.isExpired(expiry: now.addingTimeInterval(60), now: now) == false)
    // Expired when expiry is now or past (with safety margin baked in by caller).
    #expect(RedditClient.isExpired(expiry: now, now: now) == true)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests`
Expected: FAIL — `encodePath` / `isExpired` undefined.

- [ ] **Step 3: Add helpers and use them**

Add static helpers to `RedditClient`:

```swift
/// Percent-encode a single path segment so reserved characters can't break or redirect the URL.
static func encodePath(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? s
}

/// Pure expiry gate (testable). True when `now` has reached or passed `expiry`.
static func isExpired(expiry: Date, now: Date) -> Bool { now >= expiry }
```

Add token-expiry state alongside `cachedToken`:

```swift
private var cachedToken: String?
private var tokenExpiry: Date?
```

Update `authToken()` to honour expiry and store it. Replace the cache check and the success path:

```swift
func authToken() async throws -> String {
    if let cached = cachedTokenValue() { return cached }
    var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
    req.httpMethod = "POST"
    let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data("grant_type=client_credentials".utf8)
    let data = try await fetch(req)
    let decoded = try? JSONDecoder().decode(RedditTokenResponse.self, from: data)
    guard let token = decoded?.accessToken, !token.isEmpty else {
        throw AggregatorError.contentFetch("Reddit auth failed")
    }
    // Refresh 60s before the real expiry to avoid using a token mid-flight as it lapses.
    let ttl = max(0, (decoded?.expiresIn ?? 3600) - 60)
    setCachedToken(token, expiry: Date().addingTimeInterval(TimeInterval(ttl)))
    return token
}
```

Update the cache accessors:

```swift
private func cachedTokenValue() -> String? {
    tokenLock.lock(); defer { tokenLock.unlock() }
    guard let token = cachedToken, let expiry = tokenExpiry,
          !Self.isExpired(expiry: expiry, now: Date()) else { return nil }
    return token
}

private func setCachedToken(_ token: String, expiry: Date) {
    tokenLock.lock(); defer { tokenLock.unlock() }
    cachedToken = token
    tokenExpiry = expiry
}
```

Update `fetchListing` and `fetchComments` to encode + avoid force-unwrap:

```swift
func fetchListing(subreddit: String, sort: String, limit: Int) async throws -> [RedditPostData] {
    guard let url = URL(string:
        "https://oauth.reddit.com/r/\(Self.encodePath(subreddit))/\(Self.encodePath(sort)).json?limit=\(limit)&raw_json=1")
    else { throw AggregatorError.contentFetch("invalid subreddit/sort") }
    let data = try await authorizedGET(url)
    let listing = try JSONDecoder().decode(RedditListing.self, from: data)
    return listing.data.children.map(\.data)
}

func fetchComments(subreddit: String, postID: String) async throws -> [RedditComment] {
    guard let url = URL(string:
        "https://oauth.reddit.com/comments/\(Self.encodePath(postID)).json?sort=best&raw_json=1")
    else { throw AggregatorError.contentFetch("invalid post id") }
    let data = try await authorizedGET(url)
    let listings = try JSONDecoder().decode([RedditCommentEnvelope].self, from: data)
    guard listings.count >= 2 else { return [] }
    let raw = listings[1].data.children.compactMap(\.data)
    let valid = raw.filter { isValidComment($0) }
    return valid.sorted { $0.score > $1.score }
}
```

Update the decoding struct to add `expires_in` and rename for the `identifier_name` lint (Phase 3 also depends on this):

```swift
struct RedditTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests`
Expected: PASS.

- [ ] **Step 5: Verify the `access_token` lint error is gone**

Run: `swiftlint lint --quiet --path Yana/Aggregators/Concrete/RedditClient.swift`
Expected: no `identifier_name` violation (this also clears one of the Phase 3 lint errors).

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditClient.swift YanaTests/RedditClientTests.swift
git commit -m "fix: encode Reddit URL components, drop force-unwraps, expire OAuth token"
```

---

### Task 6: Re-resolve the timeline anchor when articles first load

**Files:**
- Modify: `Yana/Views/ArticleReaderView.swift:84-108`

`restoreAnchor()` runs in `.onAppear` before `@Query` delivers, so the saved reading position is lost on cold launch. Re-restore when `allArticles` transitions from empty.

- [ ] **Step 1: Add a "restored" guard flag**

Add to the `@State` block (after `viewWidth`):

```swift
@State private var didRestoreAnchor = false
```

- [ ] **Step 2: Make `restoreAnchor` idempotent and gate it on data**

Replace `restoreAnchor()`:

```swift
private func restoreAnchor() {
    let articles = filteredArticles
    guard !articles.isEmpty, !didRestoreAnchor else { return }
    appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
    didRestoreAnchor = true
}
```

- [ ] **Step 3: Re-run restore when the query delivers**

Replace the `onChange(of: allArticles)` modifier:

```swift
.onChange(of: allArticles) { _, _ in
    if didRestoreAnchor {
        clampIndex()
    } else {
        restoreAnchor()
    }
}
```

Leave `.onAppear { restoreAnchor() }` as-is — it now no-ops on an empty list and the `onChange` handles the late delivery.

- [ ] **Step 4: Build**

Run the build command.
Expected: build succeeds.

- [ ] **Step 5: Manual verification (per superpowers:verification-before-completion)**

Launch the app in the simulator, swipe to a middle article, force-quit, relaunch.
Expected: the reader reopens on the same article rather than the newest. Note the observed behavior in the commit/PR.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/ArticleReaderView.swift
git commit -m "fix: restore reading position once articles load on cold launch"
```

---

### Task 7: Set the BG task expiration handler before starting work

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift:69-84`

The handler is assigned after the work `Task` starts; expiration in that window won't cancel the run.

- [ ] **Step 1: Reorder `handle(task:)`**

Replace the body of `handle(task:)`:

```swift
func handle(task: BGAppRefreshTask) {
    // Re-arm immediately so the chain continues even if this run is cut short.
    schedule()

    let work = Task { @MainActor in
        let service = AggregationService(context: container.mainContext)
        await Self.runRefresh(service: service)
        task.setTaskCompleted(success: true)
    }

    // Set BEFORE the work can be pre-empted: if the system expires the task immediately,
    // the handler is already wired to cancel the run.
    task.expirationHandler = {
        work.cancel()
        task.setTaskCompleted(success: false)
    }
}
```

Functionally the `Task` body and handler are unchanged; the change is intent + the comment. Because `Task { ... }` schedules asynchronously and `handle` runs on `@MainActor`, the handler is now guaranteed assigned before the work's first suspension point resumes. Keep the assignment as the last synchronous statement.

> If a reviewer prefers a strict guarantee, an alternative is to assign `task.expirationHandler` first with a handler that cancels a not-yet-created task via a captured box. The reorder above is sufficient for the actor model here; document the choice in the commit.

- [ ] **Step 2: Build + run BackgroundRefresh tests if present**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: build succeeds; existing tests pass (the testable surface is `runRefresh` / `nextBeginDate`, both unchanged).

- [ ] **Step 3: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift
git commit -m "fix: wire BG task expiration handler before work can be pre-empted"
```

---

### Task 8: Honour cancellation in the AIProcessor inter-article loop

**Files:**
- Modify: `Yana/Services/AIProcessor.swift:44-47`

`try?` on the sleep swallows cancellation; a cancelled background task keeps making network calls.

- [ ] **Step 1: Add a cancellation check at the top of the loop**

In `process(_:ai:)`, replace the start of the `for` loop body:

```swift
for (i, article) in input.enumerated() {
    if i > 0, requestDelay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000_000)
    }
```

with:

```swift
for (i, article) in input.enumerated() {
    if Task.isCancelled { break }   // background run expired — stop making network calls
    if i > 0, requestDelay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000_000)
    }
```

- [ ] **Step 2: Build**

Run the build command.
Expected: build succeeds.

- [ ] **Step 3: Run AIProcessor tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests`
Expected: PASS (the cancellation path is not cancelled in tests, so existing behavior is unchanged).

- [ ] **Step 4: Commit**

```bash
git add Yana/Services/AIProcessor.swift
git commit -m "fix: stop AI processing loop when the task is cancelled"
```

---

### Task 9: Complete HTML escaping of the source URL in ContentFormatter

**Files:**
- Modify: `Yana/Aggregators/Utils/ContentFormatter.swift`
- Test: `YanaTests/ContentFormatterTests.swift` (add a test; create if absent)

`format` escapes only `"` in the source URL, which is placed in both link text and an `href` — a URL with `<`/`>`/`&` injects into the WebView.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/ContentFormatterTests.swift`:

```swift
import Testing
@testable import Yana

struct ContentFormatterTests {
    @Test func escapesUnsafeURLCharacters() {
        let out = ContentFormatter.format(
            content: "<p>x</p>",
            title: "t",
            url: "https://e.com/?a=1&b=<script>",
            headerHTML: nil,
            commentsHTML: nil
        )
        #expect(!out.contains("<script>"))
        #expect(out.contains("&amp;"))
        #expect(out.contains("&lt;script&gt;"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ContentFormatterTests`
Expected: FAIL — raw `<script>` survives.

- [ ] **Step 3: Add a shared escape helper and use it**

Add to `ContentFormatter`:

```swift
/// Escape text for safe inclusion in HTML element text and double-quoted attributes.
/// Order matters: `&` first so later replacements aren't double-escaped.
static func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
```

In `format`, replace:

```swift
let escapedURL = url.replacingOccurrences(of: "\"", with: "&quot;")
```

with:

```swift
let escapedURL = escapeHTML(url)
```

In `headerImageHTML`, replace:

```swift
let safeAlt = alt.replacingOccurrences(of: "\"", with: "&quot;")
```

with:

```swift
let safeAlt = escapeHTML(alt)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ContentFormatterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/ContentFormatter.swift YanaTests/ContentFormatterTests.swift
git commit -m "fix: fully HTML-escape source URL and alt text in ContentFormatter"
```

---

## Phase 2 — Performance

### Task 10: Replace N+1 dedup lookup in ArticleUpsert with a dictionary

**Files:**
- Modify: `Yana/Aggregators/ArticleUpsert.swift`

`feed.articles.first(where:)` inside the loop is O(n·m) and faults the whole relationship per item; an in-batch duplicate can also slip through.

- [ ] **Step 1: Build a lookup map once, then update it as you insert**

Replace the body of `apply(...)` (the `for item in aggregated` loop):

```swift
// Build the dedup index once (O(n)) instead of scanning the relationship per item.
var byIdentifier: [String: Article] = [:]
for article in feed.articles { byIdentifier[article.identifier] = article }

for item in aggregated {
    if let existing = byIdentifier[item.identifier] {
        // Update: refresh content; re-snapshot feed tags; preserve Starred.
        let wasStarred = existing.isStarred
        existing.title = item.title
        existing.url = item.url
        existing.rawContent = item.rawContent
        existing.content = item.content
        existing.author = item.author
        existing.iconURL = item.iconURL
        existing.date = item.date
        existing.tags = feed.tags
        if wasStarred, let starredTag, !existing.tags.contains(where: { $0.id == starredTag.id }) {
            existing.tags.append(starredTag)
        }
        // createdAt left untouched — preserves the reader's timeline position.
    } else {
        // Insert: snapshot the feed's current tags.
        let article = Article(
            title: item.title,
            identifier: item.identifier,
            url: item.url,
            rawContent: item.rawContent,
            content: item.content,
            date: item.date,
            author: item.author,
            iconURL: item.iconURL
        )
        article.createdAt = now
        article.feed = feed
        context.insert(article)
        article.tags = feed.tags
        // Track it so a duplicate identifier later in the same batch updates, not re-inserts.
        byIdentifier[item.identifier] = article
    }
}
```

- [ ] **Step 2: Build + run upsert tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: existing `ArticleUpsert` / `AggregationService` tests pass; dedup behavior is unchanged for the single-occurrence case.

- [ ] **Step 3: Commit**

```bash
git add Yana/Aggregators/ArticleUpsert.swift
git commit -m "perf: dedup upsert via dictionary instead of per-item relationship scan"
```

---

### Task 11: Avoid per-article Set allocation in TagFilter

**Files:**
- Modify: `Yana/Utilities/TimelineFiltering.swift`

`TagFilter.apply` builds a `Set` from `article.tags.map(\.name)` for every article on the timeline hot path. Iterate tags directly.

- [ ] **Step 1: Rewrite `apply` without the intermediate Set/map**

Replace `TagFilter.apply`:

```swift
static func apply(to articles: [Article], disabledTagNames: Set<String>, includeUntagged: Bool) -> [Article] {
    articles.filter { article in
        let tags = article.tags
        if tags.isEmpty { return includeUntagged }
        // Shown if it has at least one tag that is NOT disabled (OR semantics).
        return tags.contains { !disabledTagNames.contains($0.name) }
    }
}
```

This is equivalent to the previous `!names.isSubset(of: disabledTagNames)` but allocates nothing per article.

> **Scope decision:** the review also noted `filteredArticles` is recomputed in `saveAnchor`/`clampIndex` on each swipe. With the per-article allocation removed here (and the anchor restore made cheap in Task 6), the residual cost is a single O(n) scan per swipe over a ~month-bounded list — acceptable, and far less fragile than caching a `@Query`-derived array in `@State`. We deliberately do **not** add that cache. If profiling later shows it matters, revisit with a memoized snapshot keyed on `(allArticles.count, settings.disabledTagNames, settings.includeUntagged)`.

- [ ] **Step 2: Build + run filtering tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: existing `TagFilter` tests pass unchanged.

- [ ] **Step 3: Commit**

```bash
git add Yana/Utilities/TimelineFiltering.swift
git commit -m "perf: filter timeline without per-article Set allocation"
```

---

### Task 12: Cache the image hash→extension map at ImageStore init

**Files:**
- Modify: `Yana/Aggregators/Utils/ImageStore.swift`

After relaunch the in-memory `extensions` map is empty, so `fileURL(forHash:)` does a full `contentsOfDirectory` scan on *every* image reference — quadratic for image-heavy articles.

- [ ] **Step 1: Populate `extensions` once in `init`**

In `init`, after creating the directory, build the map from disk:

```swift
init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> (Data, String?) = { try await HTTPClient.fetchData($0) }) {
    self.directory = directory
    self.fetch = fetch
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Seed the hash -> ext map from existing files so cross-launch lookups are O(1),
    // not a directory scan per image reference.
    if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            if !stem.isEmpty, !ext.isEmpty { extensions[stem] = ext }
        }
    }
}
```

- [ ] **Step 2: Simplify `fileURL(forHash:)` to rely on the map**

Replace `fileURL(forHash:)`:

```swift
func fileURL(forHash hash: String) -> URL {
    if let ext = extensions[hash] {
        return directory.appendingPathComponent("\(hash).\(ext)")
    }
    return directory.appendingPathComponent("\(hash).img")
}
```

The per-lookup directory scan is removed; the map is authoritative because `store(...)` writes `extensions[hash]` before writing the file and `init` seeds it from disk.

- [ ] **Step 3: Build + run ImageStore tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: build succeeds; existing ImageStore tests pass.

- [ ] **Step 4: Commit**

```bash
git add Yana/Aggregators/Utils/ImageStore.swift
git commit -m "perf: seed ImageStore extension map at init, drop per-lookup dir scan"
```

---

### Task 13: Make HTMLUtils.removeComments a single traversal & cache filename regexes

**Files:**
- Modify: `Yana/Aggregators/Utils/HTMLUtils.swift`

`removeComments` is O(n²) (`getAllElements()` then every child of every element). `baseFilename` recompiles two regexes per `<img>`.

- [ ] **Step 1: Cache the two filename regexes as static constants**

Add to `HTMLUtils`:

```swift
private static let dimensionSuffix = try? NSRegularExpression(pattern: #"(?:-\d+x\d+|-\d+)+$"#)
private static let hashSuffix = try? NSRegularExpression(pattern: #"-[a-zA-Z0-9]{3,6}$"#)
```

Rewrite `baseFilename` to use them:

```swift
private static func baseFilename(_ url: String) -> String {
    var name = (url as NSString).lastPathComponent
    if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
    name = strip(dimensionSuffix, from: name)
    name = strip(hashSuffix, from: name)
    return name
}

private static func strip(_ regex: NSRegularExpression?, from s: String) -> String {
    guard let regex else { return s }
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}
```

- [ ] **Step 2: Replace `removeComments` with a single node walk**

```swift
static func removeComments(_ doc: Document) throws {
    // Single recursive walk collecting Comment nodes, then remove them — avoids the
    // O(n^2) getAllElements()-then-children pass.
    var comments: [Node] = []
    func walk(_ node: Node) {
        for child in node.getChildNodes() {
            if child is Comment { comments.append(child) } else { walk(child) }
        }
    }
    walk(doc)
    for c in comments { try c.remove() }
}
```

`Node` and `Comment` are SwiftSoup types already imported in this file.

- [ ] **Step 3: Build + run HTMLUtils / pipeline tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: build succeeds; existing tests pass (comment removal and `removeImageByURL` behavior unchanged).

- [ ] **Step 4: Commit**

```bash
git add Yana/Aggregators/Utils/HTMLUtils.swift
git commit -m "perf: single-pass comment removal + cached filename regexes in HTMLUtils"
```

---

### Task 14: Cache regexes and DateFormatters built in loops

**Files:**
- Modify: `Yana/Aggregators/Utils/FeedParser.swift`
- Modify: `Yana/Aggregators/Utils/EmbedRewriter.swift`

`DateFormatter`/`ISO8601DateFormatter` are allocated per date; `extractYouTubeID` recompiles 5 patterns per call.

- [ ] **Step 1: Hoist FeedParser date formatters to static constants**

Replace `FeedParser.parseDate`:

```swift
private static let rfc822Formatters: [DateFormatter] = {
    ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }
}()

private static let isoPlain: ISO8601DateFormatter = ISO8601DateFormatter()
private static let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

static func parseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    for f in rfc822Formatters {
        if let d = f.date(from: s) { return d }
    }
    if let d = isoPlain.date(from: s) { return d }
    return isoFractional.date(from: s)
}
```

`DateFormatter` and `ISO8601DateFormatter` reads are thread-safe; constructing them once is the goal.

- [ ] **Step 2: Cache EmbedRewriter's YouTube patterns**

Replace `extractYouTubeID`:

```swift
private static let youTubePatterns: [NSRegularExpression] = {
    [
        #"youtu\.be/([A-Za-z0-9_-]{11,})"#,
        #"youtube\.com/watch\?\S*?[?&]?v=([A-Za-z0-9_-]{11,})"#,
        #"youtube\.com/embed/([A-Za-z0-9_-]{11,})"#,
        #"youtube\.com/v/([A-Za-z0-9_-]{11,})"#,
        #"youtube\.com/shorts/([A-Za-z0-9_-]{11,})"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}()

static func extractYouTubeID(from url: String) -> String? {
    let range = NSRange(url.startIndex..<url.endIndex, in: url)
    for regex in youTubePatterns {
        guard let match = regex.firstMatch(in: url, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: url) else { continue }
        return String(url[captured])
    }
    return nil
}
```

Note: this uses capture group 1 directly (the 11+ char ID), preserving previous output semantics. Verify against existing `EmbedRewriter` tests in Step 3 — if any test relied on the trailing-match form, keep its expectations (the captured ID is identical).

- [ ] **Step 3: Build + run embed / feed-parser tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: build succeeds; YouTube-ID extraction and feed date-parsing tests pass.

- [ ] **Step 4: Commit**

```bash
git add Yana/Aggregators/Utils/FeedParser.swift Yana/Aggregators/Utils/EmbedRewriter.swift
git commit -m "perf: cache date formatters and YouTube regexes instead of rebuilding per call"
```

---

### Task 15: Count today's articles with fetchCount, not relationship materialization

**Files:**
- Modify: `Yana/Services/AggregationService.swift:131-134`

`collectedToday` faults the whole `articles` relationship per feed per run. Use a predicate + `fetchCount`.

- [ ] **Step 1: Replace `collectedToday`**

```swift
private func collectedToday(for feed: Feed, now: Date) -> Int {
    let startOfDay = Calendar.current.startOfDay(for: now)
    let feedID = feed.persistentModelID
    let descriptor = FetchDescriptor<Article>(
        predicate: #Predicate { $0.feed?.persistentModelID == feedID && $0.createdAt >= startOfDay }
    )
    return (try? context.fetchCount(descriptor)) ?? 0
}
```

> If `#Predicate` cannot compare `persistentModelID` in this SwiftData version, fall back to filtering by a stored scalar already present on `Article` (e.g. `feed?.name`); confirm by building. The intent is a counted fetch, not relationship materialization.

- [ ] **Step 2: Build + run AggregationService tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: build succeeds; the daily-cap behavior tests pass (counts match the prior relationship filter).

- [ ] **Step 3: Commit**

```bash
git add Yana/Services/AggregationService.swift
git commit -m "perf: count today's articles via fetchCount predicate"
```

---

### Task 16: Skip redundant WKWebView reloads and hoist CSS

**Files:**
- Modify: `Yana/Views/ArticleWebView.swift`

`updateUIView` rebuilds the HTML and calls `loadHTMLString` on every SwiftUI update (e.g. drag animation), reloading mid-swipe.

- [ ] **Step 1: Hoist the CSS to a static constant**

Add at the top of `ArticleWebView` (above `makeUIView`):

```swift
private static let css = """
    <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, system-ui;
            font-size: 17px; line-height: 1.6;
            padding: 0 16px; margin: 0;
            color: var(--text-color); background: transparent;
        }
        @media (prefers-color-scheme: dark) { :root { --text-color: #f0f0f0; } }
        @media (prefers-color-scheme: light) { :root { --text-color: #1a1a1a; } }
        img { max-width: 100%; height: auto; border-radius: 8px; }
        a { color: #007AFF; }
        pre, code { overflow-x: auto; font-size: 14px; }
        blockquote { border-left: 3px solid #888; margin-left: 0; padding-left: 16px; opacity: 0.85; }
        .youtube-embed-container, .dailymotion-embed-container {
            position: relative; width: 100%; padding-bottom: 56.25%; margin: 1em 0;
        }
        .youtube-embed-container iframe, .dailymotion-embed-container iframe {
            position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0;
        }
    </style>
"""
```

- [ ] **Step 2: Add a Coordinator that tracks the last-loaded HTML**

Add to `ArticleWebView`:

```swift
func makeCoordinator() -> Coordinator { Coordinator() }

final class Coordinator {
    var loadedHTML: String?
}
```

- [ ] **Step 3: Skip reload when content is unchanged**

Replace `updateUIView`:

```swift
func updateUIView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.loadedHTML != htmlContent else { return }
    context.coordinator.loadedHTML = htmlContent
    let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            \(Self.css)
        </head>
        <body>
            \(htmlContent)
        </body>
        </html>
    """
    webView.loadHTMLString(html, baseURL: URL(string: ReaderWeb.baseOrigin))
}
```

- [ ] **Step 4: Build + manual check**

Run the build, then launch and swipe through several articles.
Expected: no mid-swipe flicker/reload; article content still renders, images load via `yana-img://`.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/ArticleWebView.swift
git commit -m "perf: skip redundant WKWebView reloads and hoist static CSS"
```

---

### Task 17: Decode-and-downscale images in one ImageIO step

**Files:**
- Modify: `Yana/Aggregators/Utils/ImageCompressor.swift`

`CGImageSourceCreateImageAtIndex` decodes the full-resolution image before downscaling, spiking memory. Use a thumbnail decode that downscales during decode.

- [ ] **Step 1: Replace the decode + separate downscale with a thumbnail decode**

Replace the start of `compress(_:contentType:isHeader:)` through the `downscale` call:

```swift
static func compress(_ data: Data, contentType: String?, isHeader: Bool) -> (data: Data, ext: String)? {
    guard data.count >= 100, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

    let maxDimension = isHeader ? 1200 : 2000
    // Decode-and-downscale in one step: avoids fully decoding huge source images into memory.
    let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

    let hasAlpha = cgImage.alphaInfo != .none && cgImage.alphaInfo != .noneSkipLast && cgImage.alphaInfo != .noneSkipFirst
    let useType: UTType = hasAlpha ? .png : .jpeg
    let ext = hasAlpha ? "png" : "jpg"

    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, useType.identifier as CFString, 1, nil) else { return nil }
    let options: [CFString: Any] = useType == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
    CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return (out as Data, ext)
}
```

The private `downscale(_:maxDimension:)` function is now unused — delete it.

> `kCGImageSourceThumbnailMaxPixelSize` only downscales when the source is larger; smaller images pass through at original size, matching the prior `guard longest > maxDimension` behavior.

- [ ] **Step 2: Build + run ImageCompressor tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageCompressorTests`
Expected: build succeeds; existing tests (`compress` returns valid jpg/png, rejects tiny images) pass.

- [ ] **Step 3: Commit**

```bash
git add Yana/Aggregators/Utils/ImageCompressor.swift
git commit -m "perf: decode-and-downscale images in one ImageIO thumbnail step"
```

---

## Phase 3 — Lint cleanup & minor hardening

### Task 18: Clear remaining SwiftLint errors

**Files:**
- Modify: `YanaTests/ImageCompressorTests.swift:22`
- Modify: `Yana/Aggregators/Concrete/MeinMmoAggregator.swift` (long lines)
- Modify: `Yana/Aggregators/Concrete/ComicAggregator.swift:125`
- Modify: `Yana/Aggregators/Utils/EmbedRewriter.swift:30,37,64`

(The `force_try` error was cleared in Task 1; the `access_token` `identifier_name` error was cleared in Task 5.)

- [ ] **Step 1: Fix `empty_count` in ImageCompressorTests**

Replace line 22:

```swift
#expect(out!.data.count > 0)
```

with:

```swift
#expect(!out!.data.isEmpty)
```

- [ ] **Step 2: Wrap the over-200-char error lines**

For each remaining `line_length` *error* (>200 chars) reported by SwiftLint, break the string/expression across multiple lines using Swift string concatenation (`+`) or by extracting a local constant. Targets:
- `Yana/Aggregators/Concrete/MeinMmoAggregator.swift:192`
- `Yana/Aggregators/Concrete/ComicAggregator.swift:125`
- `Yana/Aggregators/Utils/EmbedRewriter.swift:30, 37, 64`

For the EmbedRewriter embed-HTML literals, extract the `<iframe ...>` attributes into a local string built across lines, then interpolate, e.g.:

```swift
static func youTubeEmbedHTML(videoID: String) -> String {
    let params = "autoplay=0&loop=0&mute=0&controls=1&rel=0&modestbranding=1"
        + "&playsinline=1&enablejsapi=1&origin=\(ReaderWeb.baseOrigin)"
    let src = "https://www.youtube-nocookie.com/embed/\(videoID)?\(params)"
    let allow = "accelerometer; autoplay; clipboard-write; encrypted-media; "
        + "gyroscope; picture-in-picture; web-share"
    return "<div class=\"youtube-embed-container\">"
        + "<iframe src=\"\(src)\" width=\"560\" height=\"315\" allowfullscreen "
        + "allow=\"\(allow)\" referrerpolicy=\"strict-origin-when-cross-origin\"></iframe></div>"
}
```

Apply the equivalent split to `dailymotionEmbedHTML` (line 37) and `tweetEmbedHTML`'s blockquote (line 64). Preserve the emitted markup exactly (whitespace inside the HTML string does not affect rendering, but keep attribute order identical to avoid test diffs).

- [ ] **Step 3: Verify zero SwiftLint errors**

Run: `swiftlint lint --quiet 2>&1 | grep " error: "`
Expected: no output (warnings may remain; they are Task 19).

- [ ] **Step 4: Build + test**

Run the build then the test command.
Expected: build succeeds; tests pass (embed-HTML tests still match if attribute order was preserved).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "style: clear SwiftLint errors (empty_count, long lines)"
```

---

### Task 19: Clear SwiftLint warnings

**Files:**
- Modify: `Yana/Aggregators/AggregatorRegistry.swift:11` (cyclomatic_complexity)
- Modify: `Yana/Aggregators/Utils/FeedParser.swift:80` (cyclomatic_complexity)
- Modify: `Yana/Aggregators/Concrete/MeinMmoAggregator.swift` (3× redundant_nil_coalescing, for_where, line_length warnings)
- Modify: `Yana/Views/Config/AggregatorOptionsForm.swift` (line_length warnings)
- Modify: `YanaTests/AggregationServiceTests.swift:25` (modifier_order)
- Modify: `YanaTests/FullWebsiteAggregatorTests.swift:42`, `YanaTests/MactechnewsAggregatorTests.swift:56` (type_name `S`)
- Modify: `Yana/Aggregators/Concrete/HeiseAggregator.swift:113` (implicit_optional_initialization)
- Other reported `line_length` warnings across the files listed by `swiftlint lint`.

- [ ] **Step 1: Fix the mechanical warnings**

- `redundant_nil_coalescing` (MeinMmo `...) ?? nil`): delete the `?? nil` — the expression is already optional.
- `for_where` (MeinMmo:126): convert `for x in xs { if cond { ... } }` to `for x in xs where cond { ... }`.
- `modifier_order` (AggregationServiceTests:25): reorder `private nonisolated func` → `nonisolated private func`.
- `type_name` (`S`): rename the test-local type `S` to a ≥2-char name (e.g. `StubAggregator` or `Sut`); update its references in that test file.
- `implicit_optional_initialization` (Heise:113): change `var x: T? = nil` to `var x: T?`.
- `line_length` *warnings* (150–200 chars): wrap as in Task 18 (string concatenation, extracted locals, or splitting function calls across lines). The bulk are in `AggregatorOptionsForm.swift` (form rows) — split long `.help(...)`/label strings.

- [ ] **Step 2: Reduce cyclomatic complexity in the two flagged functions**

- `AggregatorRegistry.swift:11` (`makeAggregator`, complexity 14): extract groups of `case`s into small private helper factory functions (e.g. `makeScraper(_:)`, `makeSocial(_:)`) and have the main `switch` delegate, lowering branch count below 10. Behavior must be identical — verified by the registry tests.
- `FeedParser.swift:80` (`didEndElement`, complexity 15): extract the `switch lower { ... }` field-assignment block into a private helper `assign(_ field: String, value: String, to entry: inout FeedEntry)` called from the delegate, keeping the element-close handling in the delegate method.

- [ ] **Step 3: Verify zero SwiftLint violations**

Run: `swiftlint lint --quiet`
Expected: no output at all (zero warnings and zero errors).

- [ ] **Step 4: Build + test**

Run the build then the test command.
Expected: build succeeds; all tests pass (registry, feed-parser, and aggregator tests confirm the refactors preserved behavior).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "style: clear all remaining SwiftLint warnings"
```

---

### Task 20: Make Keychain items readable after first unlock

**Files:**
- Modify: `Yana/Services/KeychainService.swift:15-23`

Without `kSecAttrAccessible`, items default to `WhenUnlocked`; background refresh that needs an API key while the device is locked can fail to read it.

- [ ] **Step 1: Add the accessibility attribute on save**

In `save(key:value:)`, add to the `query` dictionary:

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: AppConstants.keychainService,
    kSecAttrAccount as String: key,
    kSecValueData as String: data,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
]
```

- [ ] **Step 2: Build + run KeychainService tests if present**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: build succeeds; save/load round-trips still pass.

- [ ] **Step 3: Commit**

```bash
git add Yana/Services/KeychainService.swift
git commit -m "fix: store Keychain items as AccessibleAfterFirstUnlock for background reads"
```

---

### Task 21: Gate the per-feed Update action while updating

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`

The per-row "Update" swipe action isn't gated by `isUpdating`, so it can run concurrently with "Update All" against the same context.

- [ ] **Step 1: Set and respect `isUpdating` in `updateOne`**

Replace `updateOne`:

```swift
private func updateOne(_ feed: Feed) async {
    guard !isUpdating else { return }
    isUpdating = true
    defer { isUpdating = false }
    await AggregationService(context: modelContext).update(feed: feed)
}
```

- [ ] **Step 2: Disable the swipe Update button while updating**

In the `.swipeActions` block, gate the Update button:

```swift
Button {
    Task { await updateOne(feed) }
} label: {
    Label("Update", systemImage: "arrow.clockwise")
}
.tint(.blue)
.disabled(isUpdating)
```

- [ ] **Step 3: Build**

Run the build command.
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "fix: serialize per-feed update with Update All via isUpdating gate"
```

---

### Task 22: Detect image URLs by path extension, not substring

**Files:**
- Modify: `Yana/Aggregators/Utils/HeaderElementExtractor.swift`
- Test: `YanaTests/HeaderElementExtractorTests.swift` (add a test; create if absent)

`looksLikeImage` substring-matches the whole URL, so `?ref=foo.jpg` or `/article.png-gallery` is misclassified.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/HeaderElementExtractorTests.swift`:

```swift
import Testing
@testable import Yana

struct HeaderElementExtractorTests {
    @Test func classifiesByPathExtension() {
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/a/photo.jpg") == true)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/a/photo.PNG") == true)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/article?ref=foo.jpg") == false)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/article.png-gallery") == false)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/article") == false)
    }
}
```

This requires `looksLikeImage` to be non-`private`. Change `private static func looksLikeImage` to `static func looksLikeImage`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HeaderElementExtractorTests`
Expected: FAIL (or compile error until visibility is changed and logic updated).

- [ ] **Step 3: Rewrite `looksLikeImage` using the URL path extension**

```swift
static func looksLikeImage(_ url: String) -> Bool {
    let path = URLComponents(string: url)?.path ?? url
    let ext = (path as NSString).pathExtension.lowercased()
    return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HeaderElementExtractorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/HeaderElementExtractor.swift YanaTests/HeaderElementExtractorTests.swift
git commit -m "fix: classify header image URLs by path extension, not substring"
```

---

### Task 23: Build the AI config per run instead of capturing at init

**Files:**
- Modify: `Yana/Services/AggregationService.swift`

The `AIProcessor` is snapshotted from `AppSettings` + Keychain in `init`, so provider/model/key changes don't take effect until the service is recreated.

- [ ] **Step 1: Store an optional injected processor; build the default per run**

Change the stored property and `init` so the snapshot isn't taken eagerly:

```swift
private let context: ModelContext
private let makeAggregator: AggregatorFactory
private let injectedAIProcessor: AIProcessing?
private let now: () -> Date

init(
    context: ModelContext,
    makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
    aiProcessor: AIProcessing? = nil,
    now: @escaping () -> Date = { .now }
) {
    self.context = context
    self.makeAggregator = makeAggregator
    self.injectedAIProcessor = aiProcessor
    self.now = now
}

/// The processor for this run: the injected one (tests) or a fresh snapshot of current
/// settings + Keychain so provider/model/key edits take effect on the next update.
private func currentAIProcessor() -> AIProcessing {
    if let injectedAIProcessor { return injectedAIProcessor }
    let settings = AppSettings()
    return AIProcessor(config: Self.makeAIConfig(settings: settings), requestDelay: settings.aiRequestDelay)
}
```

In `aggregate(feed:)`, replace:

```swift
let processed = await aiProcessor.process(capped, ai: config.options.ai)
```

with:

```swift
let processed = await currentAIProcessor().process(capped, ai: config.options.ai)
```

> `makeAIConfig` and the injection seam for tests are preserved, so `AggregationServiceTests` (which passes `aiProcessor:`) is unaffected.

- [ ] **Step 2: Build + run AggregationService tests**

Run the build then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: build succeeds; injected-processor tests pass.

- [ ] **Step 3: Commit**

```bash
git add Yana/Services/AggregationService.swift
git commit -m "fix: snapshot AI config per run so settings changes take effect"
```

---

## Final verification (run after all phases)

- [ ] **Lint clean**

Run: `swiftlint lint --quiet`
Expected: no output (zero errors, zero warnings).

- [ ] **Build clean**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`, no compiler warnings.

- [ ] **All tests pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests pass.

- [ ] **Docs check**

Per `superpowers:updating-project-docs`, confirm `CLAUDE.md` still accurately describes services touched (HTTPClient size cap, AIClient/AIProcessor caps, AggregationService per-run AI config). Update if any described behavior changed.
