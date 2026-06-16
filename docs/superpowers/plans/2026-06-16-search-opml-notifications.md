# Search + OPML Import/Export + Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full-text article search, standard-OPML feed import/export, and opt-in new-article notifications to the Yana iOS app.

**Architecture:** Three independent feature stacks layered onto the existing Phase 4 engine. Notifications reuse the existing aggregation path by threading an inserted-article count up from `ArticleUpsert` through `AggregationService.updateAll()` to `BackgroundRefreshManager`, which posts via an injectable `Notifying` service. OPML is a pure `OPMLCodec` (XML ↔ DTO) plus a SwiftData-aware `FeedPortability` mapper. Search is in-memory filtering of a `@Query` via a pure `ArticleSearch` helper, surfaced as a new config screen.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing (`import Testing`), `UNUserNotificationCenter`, `XMLParser`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-06-16-search-opml-notifications-design.md`

**Conventions:**
- Tests are Swift Testing suites, `@MainActor`, `@testable import Yana`. In-memory SwiftData via `ModelConfiguration(isStoredInMemoryOnly: true)` with `ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, ...)`.
- New `.swift` files under `Yana/` and `YanaTests/` are picked up automatically by folder-based sources in `project.yml`. **After creating any new file, run `xcodegen generate` before building/testing.**
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- All user-facing strings use `String(localized:)` / `LocalizedStringKey`.

---

## File Structure

**Create:**
- `Yana/Services/NotificationService.swift` — `Notifying` protocol, `NewArticleNotification` gating/body helpers, `NotificationService` (UNUserNotificationCenter).
- `Yana/Services/OPMLCodec.swift` — `OPMLFeed` DTO + pure encode/decode.
- `Yana/Services/FeedPortability.swift` — `Feed` ↔ `OPMLFeed` mapping over a `ModelContext`.
- `Yana/Views/ArticleContentView.swift` — shared article body (extracted from reader).
- `Yana/Views/ArticleDetailView.swift` — read-only article screen for search results.
- `Yana/Aggregators/ArticleSearch.swift` — pure search matching/filter.
- `Yana/Views/Config/ArticleListView.swift` — searchable list in config hub.
- Tests: `YanaTests/NotificationServiceTests.swift`, `OPMLCodecTests.swift`, `FeedPortabilityTests.swift`, `ArticleSearchTests.swift`.

**Modify:**
- `Yana/Aggregators/ArticleUpsert.swift` — return inserted count.
- `Yana/Services/AggregationService.swift` — propagate inserted count from `aggregate`/`update`/`updateAll`.
- `Yana/Models/AppSettings.swift` — `notificationsEnabled` (default false).
- `Yana/Services/BackgroundRefreshManager.swift` — post notification after a background run.
- `Yana/Views/Config/SettingsScreenView.swift` — Notifications toggle.
- `Yana/Views/Config/FeedsView.swift` — Import/Export toolbar.
- `Yana/Views/Config/ConfigHubView.swift` — "Articles" row.
- `Yana/Views/ArticleReaderView.swift` — delegate body to `ArticleContentView`.
- Tests: `YanaTests/ArticleUpsertTests.swift`, `AggregationServiceTests.swift`, `BackgroundRefreshManagerTests.swift`.

---

## Feature A — Notification plumbing (counts)

### Task 1: `ArticleUpsert.apply` returns inserted count

**Files:**
- Modify: `Yana/Aggregators/ArticleUpsert.swift`
- Test: `YanaTests/ArticleUpsertTests.swift`

- [ ] **Step 1: Add failing test** — append to the `ArticleUpsertTests` suite:

```swift
@Test func returnsCountOfNewlyInsertedOnly() throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
    context.insert(feed)

    // First import: both are new.
    let firstCount = ArticleUpsert.apply([aggregated("x1"), aggregated("x2")], to: feed, starredTag: nil, context: context, now: .now)
    #expect(firstCount == 2)

    // Re-import x1 (update) + x3 (new) → only 1 newly inserted.
    let secondCount = ArticleUpsert.apply([aggregated("x1"), aggregated("x3")], to: feed, starredTag: nil, context: context, now: .now)
    #expect(secondCount == 1)
    #expect(feed.articles.count == 3)
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `apply` returns `Void`, `firstCount` won't compile / no return value.

- [ ] **Step 3: Make `apply` return the inserted count**

In `Yana/Aggregators/ArticleUpsert.swift`, change the signature and count inserts:

```swift
@discardableResult
@MainActor
static func apply(
    _ aggregated: [AggregatedArticle],
    to feed: Feed,
    starredTag: Tag?,
    context: ModelContext,
    now: Date
) -> Int {
    var inserted = 0
    for item in aggregated {
        if let existing = feed.articles.first(where: { $0.identifier == item.identifier }) {
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
            inserted += 1
        }
    }
    return inserted
}
```

`@discardableResult` keeps existing callers (which ignore the value) compiling.

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (new test + existing `ArticleUpsert` tests green).

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/ArticleUpsert.swift YanaTests/ArticleUpsertTests.swift
git commit -m "feat: ArticleUpsert returns newly-inserted count"
```

---

### Task 2: `AggregationService` propagates inserted count

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Test: `YanaTests/AggregationServiceTests.swift`

- [ ] **Step 1: Add failing test** — append to `AggregationServiceTests`:

```swift
@Test func updateAllReturnsTotalInsertedCount() async throws {
    let context = try makeContext()
    let a = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    let b = Feed(name: "B", aggregatorType: .feedContent, identifier: "b")
    context.insert(a); context.insert(b)

    let service = AggregationService(context: context) { _, _ in
        FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
    }
    let inserted = await service.updateAll()
    #expect(inserted == 4)   // 2 feeds × 2 new articles
}

@Test func updateAllReturnsZeroWhenNothingNew() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let service = AggregationService(context: context) { _, _ in
        FakeAggregator(articles: [self.aggregated("x1")])
    }
    _ = await service.updateAll()
    let second = await service.updateAll()   // same id re-imported → update, not insert
    #expect(second == 0)
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `updateAll()` returns `Void`.

- [ ] **Step 3: Thread the count through the service**

In `Yana/Services/AggregationService.swift`, change `aggregate` to return the inserted count and the three public entry points to sum/return it. Replace the methods:

```swift
/// Update all enabled feeds. One feed's failure never aborts the run.
/// Returns the total number of newly inserted articles across the run.
@discardableResult
func updateAll() async -> Int {
    isUpdating = true
    defer { isUpdating = false }
    let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
    let feeds = (try? context.fetch(descriptor)) ?? []
    var inserted = 0
    for feed in feeds {
        inserted += await aggregate(feed: feed)
    }
    cleanupAndSave()
    return inserted
}

/// Update a single feed. Returns the number of newly inserted articles.
@discardableResult
func update(feed: Feed) async -> Int {
    isUpdating = true
    defer { isUpdating = false }
    let inserted = await aggregate(feed: feed)
    cleanupAndSave()
    return inserted
}

/// Re-fetch and re-process a single article by re-running its owning feed.
@discardableResult
func update(article: Article) async -> Int {
    guard let feed = article.feed else { return 0 }
    return await update(feed: feed)
}
```

Then change `aggregate(feed:)` to return `Int`:

```swift
@discardableResult
private func aggregate(feed: Feed) async -> Int {
    let runNow = now()
    let collected = collectedToday(for: feed, now: runNow)
    let config = FeedConfig(feed: feed, collectedToday: collected)
    let credentials = AggregatorCredentials.resolved()

    guard let aggregator = makeAggregator(config, credentials) else {
        feed.lastError = AggregatorError.notImplemented(feed.type).errorDescription
        return 0
    }

    do {
        try aggregator.validate()
        let fetched = try await aggregator.aggregate()
        let fresh = fetched.filter { AggregationLogic.isWithinIntakeWindow($0.date, now: runNow) }
        let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
        let capped = Array(fresh.prefix(cap))
        let processed = await aiProcessor.process(capped, ai: config.options.ai)
        let inserted = ArticleUpsert.apply(processed, to: feed, starredTag: starredTag(), context: context, now: runNow)
        feed.lastFetchedAt = runNow
        feed.lastError = nil
        return inserted
    } catch {
        feed.lastError = error.localizedDescription
        return 0
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (new tests + all existing `AggregationService` tests green — they ignore the return value, allowed by `@discardableResult`).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat: AggregationService returns total inserted count"
```

---

### Task 3: `AppSettings.notificationsEnabled` (off by default)

**Files:**
- Modify: `Yana/Models/AppSettings.swift`
- Test: `YanaTests/AppSettingsTests.swift`

- [ ] **Step 1: Add failing test** — append to `AppSettingsTests`:

```swift
@Test func notificationsDisabledByDefault() {
    let s = AppSettings(defaults: freshDefaults())
    #expect(s.notificationsEnabled == false)
}

@Test func notificationsEnabledPersists() {
    let defaults = freshDefaults()
    let s = AppSettings(defaults: defaults)
    s.notificationsEnabled = true
    #expect(AppSettings(defaults: defaults).notificationsEnabled == true)
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `notificationsEnabled` does not exist.

- [ ] **Step 3: Add the setting**

In `Yana/Models/AppSettings.swift`, add a key constant inside `enum Key` (near the other source keys):

```swift
static let notificationsEnabled = "settings.notificationsEnabled"
```

Add the property (place it after `youtubeEnabled`):

```swift
var notificationsEnabled: Bool {
    get { defaults.bool(forKey: Key.notificationsEnabled) }
    set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
}
```

`UserDefaults.bool(forKey:)` defaults to `false` for unset keys, so no `register` entry is needed (off by default is automatic). Do **not** add it to the `register(defaults:)` dict.

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift YanaTests/AppSettingsTests.swift
git commit -m "feat: AppSettings.notificationsEnabled (off by default)"
```

---

### Task 4: `NotificationService` + gating helpers

**Files:**
- Create: `Yana/Services/NotificationService.swift`
- Test: `YanaTests/NotificationServiceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("NewArticleNotification")
struct NotificationServiceTests {
    @Test func notifiesOnlyWhenEnabledAuthorizedAndPositive() {
        #expect(NewArticleNotification.shouldNotify(enabled: true, authorized: true, insertedCount: 3) == true)
        #expect(NewArticleNotification.shouldNotify(enabled: false, authorized: true, insertedCount: 3) == false)
        #expect(NewArticleNotification.shouldNotify(enabled: true, authorized: false, insertedCount: 3) == false)
        #expect(NewArticleNotification.shouldNotify(enabled: true, authorized: true, insertedCount: 0) == false)
    }

    @Test func bodyMentionsCount() {
        #expect(NewArticleNotification.body(count: 5).contains("5"))
        #expect(NewArticleNotification.body(count: 1).contains("1"))
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `NewArticleNotification` undefined.

- [ ] **Step 3: Create the service file**

`Yana/Services/NotificationService.swift`:

```swift
import Foundation
import UserNotifications

/// Abstraction over the system notification center so the aggregation path can be tested
/// with a fake (no real authorization prompts or scheduled notifications).
protocol Notifying: Sendable {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func postNewArticles(count: Int) async
}

/// Pure gating + copy for the "new articles" notification. Kept separate from the
/// system-touching `NotificationService` so the decision logic is unit-testable.
enum NewArticleNotification {
    static func shouldNotify(enabled: Bool, authorized: Bool, insertedCount: Int) -> Bool {
        enabled && authorized && insertedCount > 0
    }

    static func body(count: Int) -> String {
        String(localized: "\(count) new articles")
    }

    static let title = String(localized: "Yana")
}

/// Concrete `Notifying` backed by `UNUserNotificationCenter`.
struct NotificationService: Notifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func postNewArticles(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = NewArticleNotification.title
        content.body = NewArticleNotification.body(count: count)
        let request = UNNotificationRequest(
            identifier: "yana.new-articles",
            content: content,
            trigger: nil   // deliver immediately
        )
        try? await center.add(request)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/NotificationService.swift YanaTests/NotificationServiceTests.swift
git commit -m "feat: NotificationService + new-article gating helpers"
```

---

### Task 5: Wire notifications into `BackgroundRefreshManager`

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift`
- Test: `YanaTests/BackgroundRefreshManagerTests.swift`

- [ ] **Step 1: Add failing tests** — append to `BackgroundRefreshManagerTests` (inside the suite):

```swift
/// Records notification posts without touching the system center.
private final class FakeNotifier: Notifying, @unchecked Sendable {
    var authorized: Bool
    var postedCounts: [Int] = []
    init(authorized: Bool) { self.authorized = authorized }
    func requestAuthorization() async -> Bool { authorized }
    func isAuthorized() async -> Bool { authorized }
    func postNewArticles(count: Int) async { postedCounts.append(count) }
}

private func freshSettings(notificationsEnabled: Bool) -> AppSettings {
    let defaults = UserDefaults(suiteName: "BGRefreshTests.\(UUID().uuidString)")!
    let s = AppSettings(defaults: defaults)
    s.notificationsEnabled = notificationsEnabled
    return s
}

@Test func postsNotificationWhenEnabledAuthorizedAndNewArticles() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let article = AggregatedArticle(title: "x1", identifier: "x1", url: "x1", rawContent: "", content: "c", date: .now, author: "", iconURL: nil)
    let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: [article]) }
    let notifier = FakeNotifier(authorized: true)

    await BackgroundRefreshManager.runRefresh(service: service, notifier: notifier, settings: freshSettings(notificationsEnabled: true))

    #expect(notifier.postedCounts == [1])
}

@Test func doesNotNotifyWhenDisabled() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let article = AggregatedArticle(title: "x1", identifier: "x1", url: "x1", rawContent: "", content: "c", date: .now, author: "", iconURL: nil)
    let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: [article]) }
    let notifier = FakeNotifier(authorized: true)

    await BackgroundRefreshManager.runRefresh(service: service, notifier: notifier, settings: freshSettings(notificationsEnabled: false))

    #expect(notifier.postedCounts.isEmpty)
    #expect(feed.articles.count == 1)   // refresh still ran
}

@Test func doesNotNotifyWhenNotAuthorized() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let article = AggregatedArticle(title: "x1", identifier: "x1", url: "x1", rawContent: "", content: "c", date: .now, author: "", iconURL: nil)
    let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: [article]) }
    let notifier = FakeNotifier(authorized: false)

    await BackgroundRefreshManager.runRefresh(service: service, notifier: notifier, settings: freshSettings(notificationsEnabled: true))

    #expect(notifier.postedCounts.isEmpty)
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `runRefresh` has no `notifier:`/`settings:` params.

- [ ] **Step 3: Update `runRefresh` and the BG handler**

In `Yana/Services/BackgroundRefreshManager.swift`, replace `runRefresh` with:

```swift
/// The work performed for one background run, isolated from `BGTask` so it can be
/// unit-tested. Runs the aggregation, then posts a "new articles" notification when the
/// user has opted in, the system authorized it, and the run imported at least one article.
/// Errors are swallowed by the caller — a failed background run must never crash the app.
@MainActor
static func runRefresh(
    service: AggregationService,
    notifier: Notifying = NotificationService(),
    settings: AppSettings = AppSettings()
) async {
    let inserted = await service.updateAll()
    guard settings.notificationsEnabled, inserted > 0 else { return }
    let authorized = await notifier.isAuthorized()
    guard NewArticleNotification.shouldNotify(enabled: true, authorized: authorized, insertedCount: inserted) else { return }
    await notifier.postNewArticles(count: inserted)
}
```

The existing `handle(task:)` already calls `await Self.runRefresh(service: service)` — defaults cover the new params, so no change is required there. (Verify the call site still compiles.)

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS — the three new tests plus the existing `runRefreshAwaitsUpdateAllAndImports` (which uses default args; `notificationsEnabled` defaults false so no system access).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift YanaTests/BackgroundRefreshManagerTests.swift
git commit -m "feat: post new-article notification after background refresh"
```

---

### Task 6: Notifications toggle in Settings

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift`

(UI wiring; no unit test — verified via build.)

- [ ] **Step 1: Read the current view** to confirm the `body` section list and the `@State private var settings` declaration.

Run: `sed -n '1,30p' Yana/Views/Config/SettingsScreenView.swift`

- [ ] **Step 2: Add a notifications section and a request-on-enable handler**

Add `notificationsSection` to the `body`'s section list (after `youtubeSection`, before `aiProviderSection`):

```swift
youtubeSection
notificationsSection
aiProviderSection
```

Add the section definition (place it next to the other private section vars):

```swift
private var notificationsSection: some View {
    Section("Notifications") {
        Toggle("Notify about new articles", isOn: Binding(
            get: { settings.notificationsEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        let granted = await NotificationService().requestAuthorization()
                        settings.notificationsEnabled = granted
                    }
                } else {
                    settings.notificationsEnabled = false
                }
            }
        ))
    }
}
```

This requests authorization the first time the user flips it on; if denied, the toggle reverts to off because `settings.notificationsEnabled` is only set to the granted value.

- [ ] **Step 3: Regenerate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift
git commit -m "feat: notifications toggle in settings (requests authorization)"
```

---

## Feature B — OPML Import / Export

### Task 7: `OPMLCodec` encode

**Files:**
- Create: `Yana/Services/OPMLCodec.swift`
- Test: `YanaTests/OPMLCodecTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("OPMLCodec")
struct OPMLCodecTests {
    @Test func encodesFeedAsOutlineWithYanaAttributes() {
        let feed = OPMLFeed(
            name: "Heise",
            identifier: "https://www.heise.de/rss/heise-atom.xml",
            aggregatorType: "heise",
            optionsJSONBase64: "eyJhIjoxfQ==",
            tags: ["Tech", "News"],
            dailyLimit: 20,
            enabled: true
        )
        let xml = OPMLCodec.encode([feed])
        #expect(xml.contains("<opml"))
        #expect(xml.contains("xmlns:yana"))
        #expect(xml.contains("text=\"Heise\""))
        #expect(xml.contains("xmlUrl=\"https://www.heise.de/rss/heise-atom.xml\""))
        #expect(xml.contains("yana:aggregatorType=\"heise\""))
        #expect(xml.contains("yana:tags=\"Tech,News\""))
        #expect(xml.contains("yana:dailyLimit=\"20\""))
        #expect(xml.contains("yana:enabled=\"true\""))
    }

    @Test func escapesSpecialCharactersInAttributes() {
        let feed = OPMLFeed(name: "A & B \"C\"", identifier: "http://x?a=1&b=2",
                            aggregatorType: "feed_content", optionsJSONBase64: "", tags: [], dailyLimit: 10, enabled: true)
        let xml = OPMLCodec.encode([feed])
        #expect(xml.contains("A &amp; B &quot;C&quot;"))
        #expect(xml.contains("a=1&amp;b=2"))
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `OPMLFeed` / `OPMLCodec` undefined.

- [ ] **Step 3: Create the DTO and encoder**

`Yana/Services/OPMLCodec.swift`:

```swift
import Foundation

/// Plain transfer object for a feed in an OPML document. SwiftData-free so the codec is
/// trivially testable. `aggregatorType`/`optionsJSONBase64` are absent (nil/empty) for
/// foreign OPML produced by other readers.
struct OPMLFeed: Equatable, Sendable {
    var name: String
    var identifier: String
    var aggregatorType: String?
    var optionsJSONBase64: String
    var tags: [String]
    var dailyLimit: Int?
    var enabled: Bool?
}

enum OPMLCodec {
    // MARK: Encode

    static func encode(_ feeds: [OPMLFeed]) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\" xmlns:yana=\"https://fa-krug.de/yana\">")
        lines.append("  <head><title>Yana Feeds</title></head>")
        lines.append("  <body>")
        for feed in feeds {
            lines.append("    " + outline(for: feed))
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static func outline(for feed: OPMLFeed) -> String {
        var attrs: [String] = [
            "text=\"\(escape(feed.name))\"",
            "title=\"\(escape(feed.name))\"",
            "type=\"rss\"",
            "xmlUrl=\"\(escape(feed.identifier))\"",
        ]
        if let type = feed.aggregatorType {
            attrs.append("yana:aggregatorType=\"\(escape(type))\"")
        }
        if !feed.optionsJSONBase64.isEmpty {
            attrs.append("yana:options=\"\(escape(feed.optionsJSONBase64))\"")
        }
        if !feed.tags.isEmpty {
            attrs.append("yana:tags=\"\(escape(feed.tags.joined(separator: ",")))\"")
        }
        if let limit = feed.dailyLimit {
            attrs.append("yana:dailyLimit=\"\(limit)\"")
        }
        if let enabled = feed.enabled {
            attrs.append("yana:enabled=\"\(enabled)\"")
        }
        return "<outline " + attrs.joined(separator: " ") + " />"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/OPMLCodec.swift YanaTests/OPMLCodecTests.swift
git commit -m "feat: OPMLCodec encode (standard OPML + yana extension attrs)"
```

---

### Task 8: `OPMLCodec` decode

**Files:**
- Modify: `Yana/Services/OPMLCodec.swift`
- Test: `YanaTests/OPMLCodecTests.swift`

- [ ] **Step 1: Add failing tests** — append to `OPMLCodecTests`:

```swift
@Test func decodeRoundTripsYanaFeed() {
    let feed = OPMLFeed(name: "Heise", identifier: "https://www.heise.de/rss/heise-atom.xml",
                        aggregatorType: "heise", optionsJSONBase64: "eyJhIjoxfQ==",
                        tags: ["Tech", "News"], dailyLimit: 20, enabled: true)
    let decoded = OPMLCodec.decode(OPMLCodec.encode([feed]))
    #expect(decoded == [feed])
}

@Test func decodeForeignOpmlYieldsNoYanaMetadata() {
    let xml = """
    <?xml version="1.0"?>
    <opml version="2.0"><body>
      <outline text="Some Blog" type="rss" xmlUrl="https://example.com/feed.xml" />
    </body></opml>
    """
    let decoded = OPMLCodec.decode(xml)
    #expect(decoded.count == 1)
    #expect(decoded[0].name == "Some Blog")
    #expect(decoded[0].identifier == "https://example.com/feed.xml")
    #expect(decoded[0].aggregatorType == nil)
    #expect(decoded[0].tags.isEmpty)
}

@Test func decodeHandlesNestedOutlines() {
    let xml = """
    <opml version="2.0"><body>
      <outline text="Folder">
        <outline text="Inner" type="rss" xmlUrl="https://a.com/f.xml" />
      </outline>
    </body></opml>
    """
    let decoded = OPMLCodec.decode(xml)
    // Only outlines carrying an xmlUrl become feeds; the container folder is skipped.
    #expect(decoded.map(\.identifier) == ["https://a.com/f.xml"])
}

@Test func decodeReturnsEmptyForMalformedXML() {
    #expect(OPMLCodec.decode("not xml at all <<<").isEmpty)
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `OPMLCodec.decode` undefined.

- [ ] **Step 3: Add the parser**

Append to `OPMLCodec` in `Yana/Services/OPMLCodec.swift`:

```swift
    // MARK: Decode

    static func decode(_ xml: String) -> [OPMLFeed] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = OutlineCollector()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.feeds
    }
}

/// Collects every `<outline>` that carries an `xmlUrl` into an `OPMLFeed`. Folder outlines
/// (no `xmlUrl`) are ignored; nested feed outlines are flattened.
private final class OutlineCollector: NSObject, XMLParserDelegate {
    var feeds: [OPMLFeed] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        guard elementName == "outline" else { return }
        // XMLParser strips namespace prefixes when namespace processing is off, so a
        // `yana:tags` attribute arrives keyed as "yana:tags".
        guard let xmlUrl = attributeDict["xmlUrl"], !xmlUrl.isEmpty else { return }
        let name = attributeDict["text"] ?? attributeDict["title"] ?? xmlUrl
        let tagsRaw = attributeDict["yana:tags"] ?? ""
        let tags = tagsRaw.isEmpty ? [] : tagsRaw.split(separator: ",").map { String($0) }
        let dailyLimit = attributeDict["yana:dailyLimit"].flatMap { Int($0) }
        let enabled = attributeDict["yana:enabled"].map { $0 == "true" }
        feeds.append(OPMLFeed(
            name: name,
            identifier: xmlUrl,
            aggregatorType: attributeDict["yana:aggregatorType"],
            optionsJSONBase64: attributeDict["yana:options"] ?? "",
            tags: tags,
            dailyLimit: dailyLimit,
            enabled: enabled
        ))
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (round-trip + foreign + nested + malformed).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/OPMLCodec.swift YanaTests/OPMLCodecTests.swift
git commit -m "feat: OPMLCodec decode (yana attrs + foreign OPML + nesting)"
```

---

### Task 9: `FeedPortability` (Feed ↔ OPML mapping)

**Files:**
- Create: `Yana/Services/FeedPortability.swift`
- Test: `YanaTests/FeedPortabilityTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("FeedPortability")
struct FeedPortabilityTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func exportThenImportRoundTripsTypeOptionsAndTags() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        context.insert(tech)
        var opts = HeiseOptions(); opts.maxComments = 9
        let feed = Feed(name: "Heise", aggregatorType: .heise, identifier: "https://heise.de/rss", dailyLimit: 15)
        feed.options = .heise(opts)
        feed.tags = [tech]
        context.insert(feed)

        let xml = FeedPortability.exportOPML(context: context)

        // Import into a fresh store.
        let fresh = try makeContext()
        let result = FeedPortability.importOPML(xml, context: fresh)
        #expect(result.imported == 1)

        let feeds = try fresh.fetch(FetchDescriptor<Feed>())
        let restored = try #require(feeds.first)
        #expect(restored.type == .heise)
        #expect(restored.dailyLimit == 15)
        #expect(restored.tags.map(\.name) == ["Tech"])
        if case let .heise(o) = restored.options { #expect(o.maxComments == 9) } else { Issue.record("wrong options case") }
    }

    @Test func importForeignOpmlCreatesFeedContentFeed() throws {
        let context = try makeContext()
        let xml = """
        <opml version="2.0"><body>
          <outline text="Blog" type="rss" xmlUrl="https://example.com/feed.xml" />
        </body></opml>
        """
        let result = FeedPortability.importOPML(xml, context: context)
        #expect(result.imported == 1)
        let feed = try #require(try context.fetch(FetchDescriptor<Feed>()).first)
        #expect(feed.type == .feedContent)
        #expect(feed.identifier == "https://example.com/feed.xml")
        #expect(feed.name == "Blog")
    }

    @Test func importSkipsDuplicateByIdentifierAndType() throws {
        let context = try makeContext()
        let existing = Feed(name: "Blog", aggregatorType: .feedContent, identifier: "https://example.com/feed.xml")
        context.insert(existing)
        let xml = """
        <opml version="2.0"><body>
          <outline text="Blog" type="rss" xmlUrl="https://example.com/feed.xml" yana:aggregatorType="feed_content" />
        </body></opml>
        """
        let result = FeedPortability.importOPML(xml, context: context)
        #expect(result.imported == 0)
        #expect(result.skipped == 1)
        #expect(try context.fetch(FetchDescriptor<Feed>()).count == 1)
    }

    @Test func importReusesExistingTagByName() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        context.insert(tech)
        let xml = """
        <opml version="2.0"><body>
          <outline text="Heise" type="rss" xmlUrl="https://heise.de/rss" yana:aggregatorType="heise" yana:tags="Tech" />
        </body></opml>
        """
        _ = FeedPortability.importOPML(xml, context: context)
        let tags = try context.fetch(FetchDescriptor<Yana.Tag>())
        #expect(tags.filter { $0.name == "Tech" }.count == 1)   // reused, not duplicated
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `FeedPortability` undefined.

- [ ] **Step 3: Create the mapper**

`Yana/Services/FeedPortability.swift`:

```swift
import Foundation
import SwiftData

/// Maps SwiftData `Feed`s to/from OPML via `OPMLCodec`. Import resolves tags by name,
/// restores typed options when present, falls back to `feedContent` for foreign OPML, and
/// dedupes against existing feeds by `(identifier, aggregatorType)`.
@MainActor
enum FeedPortability {
    struct ImportResult: Equatable {
        var imported: Int
        var skipped: Int
    }

    // MARK: Export

    static func exportOPML(context: ModelContext) -> String {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return OPMLCodec.encode(feeds.map(opmlFeed(from:)))
    }

    private static func opmlFeed(from feed: Feed) -> OPMLFeed {
        let optionsB64: String = {
            guard let data = try? JSONEncoder().encode(feed.options) else { return "" }
            return data.base64EncodedString()
        }()
        return OPMLFeed(
            name: feed.name,
            identifier: feed.identifier,
            aggregatorType: feed.aggregatorType,
            optionsJSONBase64: optionsB64,
            tags: feed.tags.filter { !$0.isBuiltIn }.map(\.name),
            dailyLimit: feed.dailyLimit,
            enabled: feed.enabled
        )
    }

    // MARK: Import

    @discardableResult
    static func importOPML(_ xml: String, context: ModelContext) -> ImportResult {
        let dtos = OPMLCodec.decode(xml)
        let existing = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        var existingKeys = Set(existing.map { "\($0.identifier)|\($0.aggregatorType)" })

        var imported = 0
        var skipped = 0
        for dto in dtos {
            let type = dto.aggregatorType.flatMap(AggregatorType.init(rawValue:)) ?? .feedContent
            let key = "\(dto.identifier)|\(type.rawValue)"
            if existingKeys.contains(key) { skipped += 1; continue }

            let feed = Feed(
                name: dto.name,
                aggregatorType: type,
                identifier: dto.identifier,
                dailyLimit: dto.dailyLimit ?? 20,
                enabled: dto.enabled ?? true,
                options: decodeOptions(dto.optionsJSONBase64, type: type)
            )
            feed.tags = resolveTags(dto.tags, context: context)
            context.insert(feed)
            existingKeys.insert(key)
            imported += 1
        }
        try? context.save()
        return ImportResult(imported: imported, skipped: skipped)
    }

    private static func decodeOptions(_ base64: String, type: AggregatorType) -> AggregatorOptions {
        guard !base64.isEmpty,
              let data = Data(base64Encoded: base64),
              let options = try? JSONDecoder().decode(AggregatorOptions.self, from: data)
        else { return type.defaultOptions }
        return options
    }

    /// Resolve tag names to `Tag`s, reusing existing (case-insensitive) matches and creating
    /// missing ones. Never creates or attaches the built-in Starred tag.
    private static func resolveTags(_ names: [String], context: ModelContext) -> [Tag] {
        guard !names.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        var byName = Dictionary(uniqueKeysWithValues: all.filter { !$0.isBuiltIn }.map { ($0.name.lowercased(), $0) })
        var result: [Tag] = []
        for name in names {
            let key = name.lowercased()
            if let tag = byName[key] {
                result.append(tag)
            } else {
                let tag = Tag(name: name)
                context.insert(tag)
                byName[key] = tag
                result.append(tag)
            }
        }
        return result
    }
}
```

**Note for implementer:** confirm `Tag`'s initializer signature is `Tag(name:)` / `Tag(name:isBuiltIn:)` (see `Yana/Models/Tag.swift`) and that `AggregatorOptions` is `Codable` (it is — see `Yana/Models/AggregatorOptions.swift`). Adjust the `Tag(name:)` call if the initializer differs.

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (round-trip, foreign, dedupe, tag-reuse).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/FeedPortability.swift YanaTests/FeedPortabilityTests.swift
git commit -m "feat: FeedPortability maps Feed <-> OPML with tag/option restore"
```

---

### Task 10: Import/Export UI in `FeedsView`

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`

(UI wiring; verified via build.)

- [ ] **Step 1: Add state, importer, exporter, and toolbar buttons**

In `Yana/Views/Config/FeedsView.swift`, add these `@State`s after `@State private var isUpdating = false`:

```swift
@State private var isImporting = false
@State private var exportURL: URL?
@State private var isExporting = false
@State private var importMessage: String?
```

Add two toolbar items to the existing `.toolbar { ... }` (after the "Update All" item):

```swift
ToolbarItem(placement: .topBarTrailing) {
    Menu {
        Button { exportOPML() } label: { Label("Export OPML", systemImage: "square.and.arrow.up") }
        Button { isImporting = true } label: { Label("Import OPML", systemImage: "square.and.arrow.down") }
    } label: {
        Image(systemName: "ellipsis.circle")
    }
}
```

Add these modifiers to the `List` (alongside `.navigationTitle`, `.overlay`, `.toolbar`):

```swift
.fileImporter(
    isPresented: $isImporting,
    allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
    allowsMultipleSelection: false
) { result in
    handleImport(result)
}
.sheet(isPresented: $isExporting) {
    if let url = exportURL { ShareSheet(activityItems: [url]) }
}
.alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
    Button("OK", role: .cancel) {}
} message: {
    Text(importMessage ?? "")
}
```

Add `import UniformTypeIdentifiers` at the top of the file (next to `import SwiftUI`).

Add these helper methods to the struct:

```swift
private func exportOPML() {
    let xml = FeedPortability.exportOPML(context: modelContext)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Yana-Feeds.opml")
    do {
        try xml.data(using: .utf8)?.write(to: url)
        exportURL = url
        isExporting = true
    } catch {
        importMessage = String(localized: "Export failed.")
    }
}

private func handleImport(_ result: Result<[URL], Error>) {
    guard case let .success(urls) = result, let url = urls.first else { return }
    let needsStop = url.startAccessingSecurityScopedResource()
    defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
    guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
        importMessage = String(localized: "Could not read the file.")
        return
    }
    let r = FeedPortability.importOPML(xml, context: modelContext)
    importMessage = String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped).")
}
```

`ShareSheet` is already defined in `Yana/Views/ArticleReaderView.swift` and is in the same module, so it is available here.

- [ ] **Step 2: Regenerate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "feat: OPML import/export from the Feeds screen"
```

---

## Feature C — Article Search

### Task 11: Extract shared `ArticleContentView` from the reader

**Files:**
- Create: `Yana/Views/ArticleContentView.swift`
- Modify: `Yana/Views/ArticleReaderView.swift`

(Refactor with no behavior change; verified via build + existing tests.)

- [ ] **Step 1: Create `ArticleContentView`** containing the article body currently inline in the reader:

`Yana/Views/ArticleContentView.swift`:

```swift
import SwiftUI

/// The scrollable article body (title, meta line, rendered HTML) plus a bottom bar with
/// open-in-browser and share. Shared by the swipe reader and the search detail screen.
struct ArticleContentView: View {
    let article: Article
    @Environment(\.openURL) private var openURL
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let feedTitle = article.feed?.name, !feedTitle.isEmpty {
                        Text(feedTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    if !article.author.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(article.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(article.date, style: .relative).font(.subheadline).foregroundStyle(.secondary)
                }

                Divider()

                ArticleWebView(htmlContent: article.content).frame(minHeight: 400)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $isShowingShare) {
            if let url = shareURL { ShareSheet(activityItems: [url]) }
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            if let url = URL(string: article.url) {
                Button { openURL(url) } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button { shareURL = url; isShowingShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
```

- [ ] **Step 2: Replace the reader's inline body with the shared view**

In `Yana/Views/ArticleReaderView.swift`:

1. Replace the body of `articleContent(_:)` so it delegates:

```swift
@ViewBuilder
private func articleContent(_ article: Article) -> some View {
    ArticleContentView(article: article)
}
```

2. Delete the now-unused `bottomBar(_:)` method.
3. Delete the now-unused `@State private var shareURL: URL?` and `@State private var isShowingShare = false`, and the `.sheet(isPresented: $isShowingShare) { ... }` modifier (share now lives inside `ArticleContentView`).

Leave the swipe gesture, toolbar, filter/settings sheets, and anchor logic untouched.

- [ ] **Step 3: Regenerate + build + test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: BUILD SUCCEEDED, all existing tests still PASS (pure refactor).

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/ArticleContentView.swift Yana/Views/ArticleReaderView.swift
git commit -m "refactor: extract shared ArticleContentView from reader"
```

---

### Task 12: `ArticleSearch` pure helper

**Files:**
- Create: `Yana/Aggregators/ArticleSearch.swift`
- Test: `YanaTests/ArticleSearchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSearch")
struct ArticleSearchTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func article(title: String = "", content: String = "", author: String = "", feedName: String = "") -> Article {
        let a = Article(title: title, identifier: UUID().uuidString, url: "u", content: content, author: author)
        if !feedName.isEmpty { a.feed = Feed(name: feedName, aggregatorType: .feedContent, identifier: "f") }
        return a
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(ArticleSearch.matches(article(title: "anything"), query: "   "))
    }

    @Test func matchesAcrossTitleContentAuthorFeedName() {
        #expect(ArticleSearch.matches(article(title: "Swift 6 ships"), query: "swift"))      // title
        #expect(ArticleSearch.matches(article(content: "<p>Concurrency</p>"), query: "concurrency")) // content
        #expect(ArticleSearch.matches(article(author: "Jane Doe"), query: "jane"))           // author
        #expect(ArticleSearch.matches(article(feedName: "Heise"), query: "heise"))           // feed name
    }

    @Test func nonMatchIsExcluded() {
        #expect(!ArticleSearch.matches(article(title: "Kotlin"), query: "swift"))
    }

    @Test func filterReturnsOnlyMatches() {
        let articles = [article(title: "Swift"), article(title: "Rust"), article(author: "swifty")]
        #expect(ArticleSearch.filter(articles, query: "swift").count == 2)
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `ArticleSearch` undefined.

- [ ] **Step 3: Create the helper**

`Yana/Aggregators/ArticleSearch.swift`:

```swift
import Foundation

/// Case/diacritic-insensitive substring search across an article's title, content (HTML),
/// author, and source feed name. In-memory filtering is fine given retention keeps the
/// article set bounded (~one month).
@MainActor
enum ArticleSearch {
    static func matches(_ article: Article, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystacks = [article.title, article.content, article.author, article.feed?.name ?? ""]
        return haystacks.contains { $0.localizedStandardContains(q) }
    }

    static func filter(_ articles: [Article], query: String) -> [Article] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return articles }
        return articles.filter { matches($0, query: q) }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/ArticleSearch.swift YanaTests/ArticleSearchTests.swift
git commit -m "feat: ArticleSearch pure title/content/author/feed matcher"
```

---

### Task 13: `ArticleDetailView` + `ArticleListView`

**Files:**
- Create: `Yana/Views/ArticleDetailView.swift`
- Create: `Yana/Views/Config/ArticleListView.swift`

(UI; verified via build.)

- [ ] **Step 1: Create `ArticleDetailView`**

`Yana/Views/ArticleDetailView.swift`:

```swift
import SwiftUI

/// Read-only article screen shown when a search result is tapped. Reuses the shared body.
struct ArticleDetailView: View {
    let article: Article

    var body: some View {
        ArticleContentView(article: article)
            .navigationTitle(article.feed?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 2: Create `ArticleListView`**

`Yana/Views/Config/ArticleListView.swift`:

```swift
import SwiftData
import SwiftUI

/// Searchable list of all articles (newest first), reachable from the config hub. Tapping a
/// row opens a read-only detail; search matches title/content/author/feed name in memory.
struct ArticleListView: View {
    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @State private var searchText = ""

    private var results: [Article] {
        ArticleSearch.filter(allArticles, query: searchText)
    }

    var body: some View {
        List(results) { article in
            NavigationLink {
                ArticleDetailView(article: article)
            } label: {
                row(article)
            }
        }
        .navigationTitle("Articles")
        .searchable(text: $searchText, prompt: Text("Search articles"))
        .overlay {
            if results.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Articles", systemImage: "tray",
                                           description: Text("Add feeds and refresh to see articles here."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func row(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if let name = article.feed?.name, !name.isEmpty {
                    Text(name).foregroundStyle(Color.accentColor)
                }
                Text("· \(article.date, style: .date)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Regenerate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/ArticleDetailView.swift Yana/Views/Config/ArticleListView.swift
git commit -m "feat: searchable ArticleListView + read-only ArticleDetailView"
```

---

### Task 14: Add "Articles" to the config hub

**Files:**
- Modify: `Yana/Views/Config/ConfigHubView.swift`

- [ ] **Step 1: Add the navigation row**

In `Yana/Views/Config/ConfigHubView.swift`, add this `NavigationLink` between the Tags link and the Settings link:

```swift
NavigationLink {
    ArticleListView()
} label: {
    Label("Articles", systemImage: "magnifyingglass")
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/ConfigHubView.swift
git commit -m "feat: Articles (search) entry in the configuration hub"
```

---

## Task 15: Final verification + docs

**Files:**
- Modify: `CLAUDE.md` (move Search / Share-portability / Notifications from "Enhanced" notes as appropriate), `Yana/Resources/Localizable.xcstrings` (auto-extracted on build via `SWIFT_EMIT_LOC_STRINGS`).

- [ ] **Step 1: Full regenerate, build, and test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: BUILD SUCCEEDED, ALL tests PASS.

- [ ] **Step 2: Update project docs**

Invoke the `updating-project-docs` skill (or manually): note in `CLAUDE.md` that article search, OPML import/export, and opt-in new-article notifications are now implemented (under the relevant Services/Views descriptions and the Planned-Features list).

- [ ] **Step 3: Commit docs**

```bash
git add CLAUDE.md Yana/Resources/Localizable.xcstrings
git commit -m "docs: record search, OPML, notifications features"
```

---

## Self-Review Notes (for the executor)

- **Spec coverage:** Search (Tasks 11–14), OPML import/export with yana extension attrs + foreign-OPML fallback + dedupe + tag reuse (Tasks 7–10), notifications off-by-default + count plumbing + bg-only posting + settings toggle (Tasks 1–6). All spec sections covered.
- **Type consistency:** `apply` → `Int` (Task 1) consumed in Task 2; `updateAll() -> Int` (Task 2) consumed in Task 5; `Notifying`/`NewArticleNotification` (Task 4) used in Tasks 5–6; `OPMLFeed`/`OPMLCodec.encode`/`.decode` (Tasks 7–8) used by `FeedPortability` (Task 9) used by `FeedsView` (Task 10); `ArticleContentView` (Task 11) used by `ArticleDetailView` (Task 13); `ArticleSearch` (Task 12) used by `ArticleListView` (Task 13).
- **Verify before relying on:** `Tag(name:)` initializer and `Article(title:identifier:url:content:author:)` initializer signatures (both used in test fixtures) — confirm against `Yana/Models/Tag.swift` and `Yana/Models/Article.swift`; adjust calls if argument labels differ.
