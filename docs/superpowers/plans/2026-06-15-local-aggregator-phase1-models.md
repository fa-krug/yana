# Local Aggregator — Phase 1 (Docs + Models) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Google Reader server-client foundation with a local, SwiftData-backed aggregator foundation — data models, the typed options system, the aggregator skeleton, app-settings storage, and the app rewiring needed to compile and run as a local-only shell.

**Architecture:** SwiftData becomes the single source of truth (`Feed`, `FeedGroup`, `Article` `@Model`s). Feeds carry an `AggregatorType` and a typed `AggregatorOptions` Codable enum. A pluggable `Aggregator` protocol + empty `AggregatorRegistry` are defined for Phase 3. `AppState` becomes thin UI state; all server/auth code is deleted. The swipe reader is rewired to read from SwiftData. No feed-creation UI (Phase 2) and no concrete aggregation (Phase 3) yet.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen.

---

## Notes for the implementer

- **XcodeGen globs the `Yana/` folder.** After creating or deleting any file under `Yana/`, run `xcodegen generate` before building so the `.xcodeproj` picks up the change.
- **Test command** (runs the whole `YanaTests` bundle on the simulator):
  ```bash
  xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests test
  ```
  This is slow (simulator boot + build). Expect a minute or more per run. When a step says "verify the test fails", a compile failure or assertion failure both count.
- **Build-only command** (for the view-rewiring task):
  ```bash
  xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
  ```
- The `YanaTests` target compiles the app sources (see `project.yml`), so model/type code is testable directly without `@testable import`.

---

## Task 1: Rewrite project documentation (CLAUDE.md)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the "What This Is" section**

In `CLAUDE.md`, replace the `## What This Is` paragraph with:

```markdown
## What This Is

Yana iOS is a **native SwiftUI iOS app** that is a fully **self-contained RSS/content
aggregator**. It fetches, parses, and processes feeds on-device and stores everything
locally with SwiftData. There is no server and no network authentication — it mirrors the
aggregation model of the [Yana server](../Yana) but runs entirely on the phone. The app is
designed for privacy-conscious users who want their feeds without any backend.
```

- [ ] **Step 2: Replace the Architecture section**

Replace the entire `## Architecture` section (from `### SwiftUI + Google Reader API` through the end of `### Yana Server API Reference`, i.e. up to but not including `### Tests`) with:

```markdown
### SwiftUI + SwiftData + local aggregation

- **Models** (`Yana/Models/`): SwiftData `@Model` classes — `Feed`, `FeedGroup`, `Article` —
  plus the typed `AggregatorOptions` enum and the `AppSettings` preferences store.
- **Aggregators** (`Yana/Aggregators/`): the pluggable aggregation system — `AggregatorType`
  (one case per content source), the `Aggregator` protocol, `AggregatedArticle` DTO, and
  `AggregatorRegistry`. Concrete aggregators are added incrementally.
- **Services** (`Yana/Services/`): `AggregationService` (orchestrates feed updates and
  upserts into SwiftData) and `KeychainService` (stores aggregator API keys).
- **Views** (`Yana/Views/`): the swipe-through `ArticleReaderView` (home surface) and the
  configuration hub (feeds, groups, article list, settings).
- **Utilities** (`Yana/Utilities/`): constants and extensions.

### Project structure

- `Yana/YanaApp.swift` — app entry point; creates the SwiftData `ModelContainer`
- `Yana/ContentView.swift` — root view (opens directly into the reader; no auth gate)
- `Yana/Models/AppState.swift` — thin observable UI state (scope, current index, errors)
- `Yana/Utilities/Constants.swift` — app constants

### Key patterns

- **No server:** all content is aggregated on-device. There is no login.
- **SwiftData source of truth:** views read via `@Query`; `AggregationService` writes.
- **Pluggable aggregators:** each content source is an `Aggregator` keyed by `AggregatorType`.
- **Typed options:** per-feed config is a `Codable` `AggregatorOptions` enum, not a JSON blob.
- **Swift 6:** strict concurrency with `@MainActor` annotations throughout.
- **Platform:** iOS 26.0+ (iPhone and iPad).

### Aggregator types

`AggregatorType` mirrors the Yana server's aggregators: `fullWebsite`, `feedContent`
(RSS/Atom), the managed scrapers (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
`caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`), and the social/media sources (`youtube`,
`reddit`, `podcast`). Reddit and YouTube require user-supplied API keys (stored in Keychain).
```

- [ ] **Step 3: Update the Planned Features section**

In `## Planned Features`, replace items 1–8 of the `### Core (MVP)` list with:

```markdown
1. **Feed configuration** — create/edit/delete feeds and groups, choose an aggregator type, set per-feed options
2. **Local aggregation** — fetch & parse feeds on-device, store articles in SwiftData
3. **Article list** — list all articles, filter by feed/group and read/unread/starred
4. **Article detail** — render article HTML content in the swipe reader
5. **Read/Unread & Starred** — mark articles read/starred locally
6. **Force update** — update all feeds, a single feed, or a single article on demand
7. **Background refresh** — best-effort periodic aggregation via BGAppRefreshTask
8. **AI post-processing** — optional summarize / improve / translate per feed
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: rewrite CLAUDE.md for local-aggregator architecture"
```

---

## Task 2: AggregatorType enum + metadata

**Files:**
- Create: `Yana/Aggregators/AggregatorType.swift`
- Test: `YanaTests/AggregatorTypeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorTypeTests.swift`:

```swift
import Testing
@testable import Yana

@Suite("AggregatorType")
struct AggregatorTypeTests {
    @Test func hasAllFourteenCases() {
        #expect(AggregatorType.allCases.count == 14)
    }

    @Test func rawValuesMatchYanaServer() {
        #expect(AggregatorType.fullWebsite.rawValue == "full_website")
        #expect(AggregatorType.feedContent.rawValue == "feed_content")
        #expect(AggregatorType.reddit.rawValue == "reddit")
        #expect(AggregatorType.youtube.rawValue == "youtube")
    }

    @Test func identifierKindVariesByType() {
        #expect(AggregatorType.reddit.identifierKind == .subreddit)
        #expect(AggregatorType.youtube.identifierKind == .youtubeChannel)
        #expect(AggregatorType.feedContent.identifierKind == .url)
        #expect(AggregatorType.oglaf.identifierKind == .none)
    }

    @Test func requiredAPIKeyVariesByType() {
        #expect(AggregatorType.reddit.requiredAPIKey == .reddit)
        #expect(AggregatorType.youtube.requiredAPIKey == .youtube)
        #expect(AggregatorType.feedContent.requiredAPIKey == AggregatorAPIKey.none)
    }

    @Test func displayNameIsHumanReadable() {
        #expect(AggregatorType.feedContent.displayName == "Feed Content (RSS/Atom)")
        #expect(AggregatorType.fullWebsite.displayName == "Full Website")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregatorType test
```
Expected: FAIL — `AggregatorType` is not defined (compile error).

- [ ] **Step 3: Implement `AggregatorType`**

Create `Yana/Aggregators/AggregatorType.swift`:

```swift
import Foundation

/// What kind of value the feed's `identifier` holds for a given aggregator.
enum AggregatorIdentifierKind: Sendable {
    case url            // a feed/website/podcast URL
    case subreddit      // a subreddit name, e.g. "swift"
    case youtubeChannel // a YouTube channel id/handle
    case none           // fixed source, no identifier needed
}

/// Which user-supplied API key an aggregator needs.
enum AggregatorAPIKey: Sendable {
    case none
    case reddit
    case youtube
}

/// One case per content source, mirroring the Yana server's aggregator choices.
enum AggregatorType: String, CaseIterable, Codable, Sendable, Identifiable {
    case fullWebsite = "full_website"
    case feedContent = "feed_content"
    case heise
    case merkur
    case tagesschau
    case explosm
    case darkLegacy = "dark_legacy"
    case caschysBlog = "caschys_blog"
    case mactechnews
    case oglaf
    case meinMmo = "mein_mmo"
    case youtube
    case reddit
    case podcast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullWebsite: "Full Website"
        case .feedContent: "Feed Content (RSS/Atom)"
        case .heise: "Heise"
        case .merkur: "Merkur"
        case .tagesschau: "Tagesschau"
        case .explosm: "Explosm"
        case .darkLegacy: "Dark Legacy Comics"
        case .caschysBlog: "Caschy's Blog"
        case .mactechnews: "MacTechNews"
        case .oglaf: "Oglaf"
        case .meinMmo: "Mein-MMO"
        case .youtube: "YouTube"
        case .reddit: "Reddit"
        case .podcast: "Podcast"
        }
    }

    var identifierKind: AggregatorIdentifierKind {
        switch self {
        case .reddit: .subreddit
        case .youtube: .youtubeChannel
        case .explosm, .darkLegacy, .oglaf, .tagesschau: .none
        default: .url
        }
    }

    var requiredAPIKey: AggregatorAPIKey {
        switch self {
        case .reddit: .reddit
        case .youtube: .youtube
        default: .none
        }
    }

    /// The default typed options for a freshly created feed of this type.
    var defaultOptions: AggregatorOptions {
        switch self {
        case .fullWebsite: .fullWebsite(WebsiteOptions())
        case .feedContent: .feedContent(FeedContentOptions())
        case .reddit: .reddit(RedditOptions())
        case .youtube: .youtube(YouTubeOptions())
        case .podcast: .podcast(PodcastOptions())
        default: .managed(ManagedOptions())
        }
    }
}
```

> Note: `defaultOptions` references `AggregatorOptions` and its structs, defined in Task 3.
> This file will not compile until Task 3 is complete. That is expected — Task 3 is
> additive and finishes the pair. Run this task's test only after Task 3.

- [ ] **Step 4: Commit (deferred to Task 3)**

Do not commit yet — `AggregatorType.swift` depends on Task 3's types. Proceed to Task 3 and commit them together.

---

## Task 3: AggregatorOptions (typed Codable) + AIOptions

**Files:**
- Create: `Yana/Models/AggregatorOptions.swift`
- Test: `YanaTests/AggregatorOptionsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorOptionsTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregatorOptions")
struct AggregatorOptionsTests {
    private func roundTrip(_ value: AggregatorOptions) throws -> AggregatorOptions {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AggregatorOptions.self, from: data)
    }

    @Test func websiteOptionsRoundTrip() throws {
        var opts = WebsiteOptions()
        opts.useFullContent = false
        opts.customContentSelector = "article.main"
        opts.ai.summarize = true
        let decoded = try roundTrip(.fullWebsite(opts))
        guard case .fullWebsite(let out) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(out.useFullContent == false)
        #expect(out.customContentSelector == "article.main")
        #expect(out.ai.summarize == true)
    }

    @Test func redditOptionsRoundTrip() throws {
        var opts = RedditOptions()
        opts.subredditSort = "top"
        opts.commentLimit = 25
        let decoded = try roundTrip(.reddit(opts))
        guard case .reddit(let out) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(out.subredditSort == "top")
        #expect(out.commentLimit == 25)
    }

    @Test func defaultsMatchExpectations() {
        #expect(WebsiteOptions().useFullContent == true)
        #expect(RedditOptions().subredditSort == "hot")
        #expect(PodcastOptions().includePlayer == true)
        #expect(AIOptions().translateLanguage == "English")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregatorOptions test
```
Expected: FAIL — types not defined (compile error).

- [ ] **Step 3: Implement `AggregatorOptions`**

Create `Yana/Models/AggregatorOptions.swift`:

```swift
import Foundation

/// AI post-processing toggles, shared by every aggregator (mirrors the Yana server's
/// shared `ai_*` options).
struct AIOptions: Codable, Sendable, Equatable {
    var summarize = false
    var improveWriting = false
    var translate = false
    var translateLanguage = "English"
}

struct WebsiteOptions: Codable, Sendable, Equatable {
    var useFullContent = true
    var customContentSelector = ""
    var customSelectorsToRemove = ""
    var ai = AIOptions()
}

struct FeedContentOptions: Codable, Sendable, Equatable {
    /// When true, follow each entry's link and extract the full article body.
    var fetchFullContent = false
    var ai = AIOptions()
}

struct RedditOptions: Codable, Sendable, Equatable {
    var subredditSort = "hot"   // hot | new | top | rising
    var minComments = 5
    var commentLimit = 10
    var includeHeaderImage = true
    var ai = AIOptions()
}

struct YouTubeOptions: Codable, Sendable, Equatable {
    var commentLimit = 10
    var ai = AIOptions()
}

struct PodcastOptions: Codable, Sendable, Equatable {
    var includePlayer = true
    var includeDownloadLink = true
    var artworkSize = 300
    var ai = AIOptions()
}

/// Shared options shape for the managed site-specific scrapers. Individual scrapers read
/// the subset relevant to them; unused flags are harmless.
struct ManagedOptions: Codable, Sendable, Equatable {
    var includeComments = true
    var maxComments = 5
    var showAltText = true
    var skipVideos = true
    var skipLivestreams = true
    var skipAds = true
    var combinePages = true
    var removeEmptyElements = true
    var ai = AIOptions()
}

/// Typed per-feed aggregator configuration. Swift synthesizes `Codable` for enums with
/// `Codable` associated values; SwiftData persists this as a composite attribute.
enum AggregatorOptions: Codable, Sendable, Equatable {
    case fullWebsite(WebsiteOptions)
    case feedContent(FeedContentOptions)
    case reddit(RedditOptions)
    case youtube(YouTubeOptions)
    case podcast(PodcastOptions)
    case managed(ManagedOptions)

    /// The AI block, regardless of which case is active.
    var ai: AIOptions {
        switch self {
        case .fullWebsite(let o): o.ai
        case .feedContent(let o): o.ai
        case .reddit(let o): o.ai
        case .youtube(let o): o.ai
        case .podcast(let o): o.ai
        case .managed(let o): o.ai
        }
    }
}
```

- [ ] **Step 4: Run both Task 2 and Task 3 tests to verify they pass**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregatorType -only-testing:YanaTests/AggregatorOptions test
```
Expected: PASS (both suites).

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/AggregatorType.swift Yana/Models/AggregatorOptions.swift YanaTests/AggregatorTypeTests.swift YanaTests/AggregatorOptionsTests.swift
git commit -m "feat: add AggregatorType and typed AggregatorOptions"
```

---

## Task 4: Aggregator protocol, AggregatedArticle DTO, AggregatorRegistry

**Files:**
- Create: `Yana/Aggregators/AggregatedArticle.swift`
- Create: `Yana/Aggregators/Aggregator.swift`
- Create: `Yana/Aggregators/AggregatorRegistry.swift`
- Test: `YanaTests/AggregatorRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry")
struct AggregatorRegistryTests {
    @Test func returnsNilForUnregisteredType() {
        // No concrete aggregators are registered in Phase 1.
        #expect(AggregatorRegistry.shared.makeAggregator(for: .feedContent, identifier: "https://example.com/feed", options: .feedContent(FeedContentOptions())) == nil)
    }

    @Test func aggregatedArticleStoresAllFields() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = AggregatedArticle(
            title: "Hello",
            identifier: "https://example.com/post/1",
            url: "https://example.com/post/1",
            rawContent: "<p>raw</p>",
            content: "<p>clean</p>",
            date: date,
            author: "Ada",
            iconURL: nil
        )
        #expect(a.title == "Hello")
        #expect(a.identifier == "https://example.com/post/1")
        #expect(a.date == date)
        #expect(a.author == "Ada")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregatorRegistry test
```
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement the DTO**

Create `Yana/Aggregators/AggregatedArticle.swift`:

```swift
import Foundation

/// Plain value returned by an aggregator's `aggregate()`. Decoupled from the SwiftData
/// `Article`; `AggregationService` upserts these into the store.
struct AggregatedArticle: Sendable, Equatable {
    var title: String
    var identifier: String   // URL or external id; dedup key within a feed
    var url: String          // link to the original article
    var rawContent: String
    var content: String
    var date: Date
    var author: String
    var iconURL: String?
}
```

- [ ] **Step 4: Implement the protocol**

Create `Yana/Aggregators/Aggregator.swift`:

```swift
import Foundation

/// Resolved secrets handed to an aggregator at construction time.
struct AggregatorCredentials: Sendable {
    var redditClientID: String?
    var redditClientSecret: String?
    var youtubeAPIKey: String?
}

/// A pluggable content source. Concrete implementations are added in Phase 3.
protocol Aggregator: Sendable {
    static var type: AggregatorType { get }

    /// Validate configuration before a run. Throws if the feed is misconfigured.
    func validate() throws

    /// Fetch and return articles for the feed.
    func aggregate() async throws -> [AggregatedArticle]
}

enum AggregatorError: Error, LocalizedError {
    case missingIdentifier
    case missingAPIKey(AggregatorAPIKey)
    case notImplemented(AggregatorType)

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            String(localized: "This feed needs an identifier (URL, subreddit, or channel).")
        case .missingAPIKey:
            String(localized: "This aggregator requires an API key. Add it in Settings.")
        case .notImplemented(let type):
            String(localized: "The \(type.displayName) aggregator is not available yet.")
        }
    }
}
```

- [ ] **Step 5: Implement the registry**

Create `Yana/Aggregators/AggregatorRegistry.swift`:

```swift
import Foundation

/// Maps an `AggregatorType` to a concrete `Aggregator`. Phase 1 registers nothing;
/// Phase 3 fills in concrete factories.
final class AggregatorRegistry: Sendable {
    static let shared = AggregatorRegistry()

    private init() {}

    /// Build an aggregator for the given type, or `nil` if none is registered yet.
    func makeAggregator(
        for type: AggregatorType,
        identifier: String,
        options: AggregatorOptions,
        credentials: AggregatorCredentials = .init()
    ) -> Aggregator? {
        // Phase 3: switch over `type` and return concrete aggregators.
        nil
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregatorRegistry test
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Yana/Aggregators/AggregatedArticle.swift Yana/Aggregators/Aggregator.swift Yana/Aggregators/AggregatorRegistry.swift YanaTests/AggregatorRegistryTests.swift
git commit -m "feat: add Aggregator protocol, AggregatedArticle, and registry skeleton"
```

---

## Task 5: AppSettings (UserDefaults) + KeychainService API-key helpers

**Files:**
- Create: `Yana/Models/AppSettings.swift`
- Modify: `Yana/Services/KeychainService.swift`
- Test: `YanaTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AppSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    @Test func hasSaneDefaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.activeAIProvider == .none)
        #expect(settings.retentionDays == 30)
        #expect(settings.backgroundInterval == 1800)
    }

    @Test func persistsChanges() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.retentionDays = 7
        settings.activeAIProvider = .anthropic

        // A new instance backed by the same defaults sees the change.
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.retentionDays == 7)
        #expect(reloaded.activeAIProvider == .anthropic)
    }

    @Test func keychainAPIKeyRoundTrip() {
        KeychainService.saveAPIKey("secret-123", for: .youtubeAPIKey)
        #expect(KeychainService.loadAPIKey(for: .youtubeAPIKey) == "secret-123")
        KeychainService.deleteAPIKey(for: .youtubeAPIKey)
        #expect(KeychainService.loadAPIKey(for: .youtubeAPIKey) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AppSettings test
```
Expected: FAIL — `AppSettings` and the new keychain helpers are not defined.

- [ ] **Step 3: Implement `AppSettings`**

Create `Yana/Models/AppSettings.swift`:

```swift
import Foundation

enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case none
    case openai
    case anthropic
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }
}

/// Non-secret user preferences, backed by UserDefaults. Secrets live in `KeychainService`.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let activeAIProvider = "settings.activeAIProvider"
        static let retentionDays = "settings.retentionDays"
        static let backgroundInterval = "settings.backgroundInterval"
    }

    var activeAIProvider: AIProvider {
        get {
            guard let raw = defaults.string(forKey: Key.activeAIProvider),
                  let provider = AIProvider(rawValue: raw) else { return .none }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.activeAIProvider) }
    }

    /// Read articles older than this many days are eligible for cleanup. Default 30.
    var retentionDays: Int {
        get {
            let value = defaults.integer(forKey: Key.retentionDays)
            return value == 0 ? 30 : value
        }
        set { defaults.set(newValue, forKey: Key.retentionDays) }
    }

    /// Background refresh interval in seconds. Default 1800 (30 min).
    var backgroundInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.backgroundInterval)
            return value == 0 ? 1800 : value
        }
        set { defaults.set(newValue, forKey: Key.backgroundInterval) }
    }
}
```

- [ ] **Step 4: Add API-key helpers to KeychainService and remove token helpers**

In `Yana/Services/KeychainService.swift`, replace the `// MARK: - Keys` block and the entire `// MARK: - Convenience Methods` section (the `authTokenKey`/`serverURLKey`/`emailKey` constants and the `saveCredentials`/`loadServerURL`/`loadEmail`/`loadAuthToken`/`clearAll` methods) with:

```swift
    // MARK: - API Keys

    enum APIKeyItem: String, Sendable {
        case redditClientID = "reddit_client_id"
        case redditClientSecret = "reddit_client_secret"
        case youtubeAPIKey = "youtube_api_key"
        case openaiAPIKey = "openai_api_key"
        case anthropicAPIKey = "anthropic_api_key"
        case geminiAPIKey = "gemini_api_key"
    }

    @discardableResult
    static func saveAPIKey(_ value: String, for item: APIKeyItem) -> Bool {
        save(key: item.rawValue, value: value)
    }

    static func loadAPIKey(for item: APIKeyItem) -> String? {
        load(key: item.rawValue)
    }

    @discardableResult
    static func deleteAPIKey(for item: APIKeyItem) -> Bool {
        delete(key: item.rawValue)
    }
```

Leave the `save(key:value:)`, `load(key:)`, and `delete(key:)` core operations unchanged.

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AppSettings test
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Services/KeychainService.swift YanaTests/AppSettingsTests.swift
git commit -m "feat: add AppSettings store and Keychain API-key helpers"
```

---

## Task 6: SwiftData models (Feed, FeedGroup, Article)

**Files:**
- Create: `Yana/Models/FeedGroup.swift`
- Create: `Yana/Models/Feed.swift`
- Create: `Yana/Models/Article.swift` (replaces the old value-type file)
- Delete: old `Yana/Models/Feed.swift` content (overwritten below) — note `Feed.swift` already exists as a struct; this task overwrites it.
- Test: `YanaTests/ModelTests.swift`

> This task introduces `@Model` types named `Article`, `Feed`, and `FeedGroup`, which
> collide with the existing value-type `Article`/`Feed`/`FeedGroup`. Those old structs are
> referenced by `AppState`, `APIClient`, and the views — all of which are removed/rewired
> in Task 7. **Therefore the project will not build between Task 6 and Task 7.** Do the
> model tests in this task against an in-memory container (which compiles once the old
> structs are gone), and do not run a full build until Task 7. To keep Task 6's own test
> runnable, this task also deletes the old struct files and the server code; the views are
> fixed in Task 7. If you prefer a single green commit, treat Tasks 6 and 7 as one unit and
> commit only at the end of Task 7.

- [ ] **Step 1: Delete the old value-type model files and server code**

```bash
git rm Yana/Models/APIModels.swift Yana/Services/APIClient.swift
```

We will overwrite `Yana/Models/Article.swift` and `Yana/Models/Feed.swift` in the next steps.

- [ ] **Step 2: Write the failing test**

Create `YanaTests/ModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SwiftData Models")
struct ModelTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Feed.self, FeedGroup.self, Article.self,
            configurations: config
        )
        return ModelContext(container)
    }

    @Test func insertAndFetchFeed() throws {
        let context = try makeContext()
        let feed = Feed(name: "Swift Blog", aggregatorType: .feedContent, identifier: "https://swift.org/atom.xml")
        context.insert(feed)
        try context.save()

        let feeds = try context.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count == 1)
        #expect(feeds.first?.name == "Swift Blog")
        #expect(feeds.first?.type == .feedContent)
    }

    @Test func feedStoresTypedOptions() throws {
        let context = try makeContext()
        let feed = Feed(name: "R", aggregatorType: .reddit, identifier: "swift")
        var opts = RedditOptions()
        opts.subredditSort = "top"
        feed.options = .reddit(opts)
        context.insert(feed)
        try context.save()

        let reloaded = try context.fetch(FetchDescriptor<Feed>()).first
        guard case .reddit(let out)? = reloaded?.options else {
            Issue.record("expected reddit options"); return
        }
        #expect(out.subredditSort == "top")
    }

    @Test func groupFeedRelationship() throws {
        let context = try makeContext()
        let group = FeedGroup(name: "Tech")
        let feed = Feed(name: "Heise", aggregatorType: .heise, identifier: "https://heise.de")
        feed.group = group
        context.insert(group)
        context.insert(feed)
        try context.save()

        let reloadedGroup = try context.fetch(FetchDescriptor<FeedGroup>()).first
        #expect(reloadedGroup?.feeds.count == 1)
        #expect(reloadedGroup?.feeds.first?.name == "Heise")
    }

    @Test func deletingFeedCascadesToArticles() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "https://x.com/feed")
        let article = Article(
            title: "Post", identifier: "https://x.com/1", url: "https://x.com/1",
            rawContent: "<p>r</p>", content: "<p>c</p>", date: .now, author: "A"
        )
        article.feed = feed
        context.insert(feed)
        context.insert(article)
        try context.save()

        context.delete(feed)
        try context.save()

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }
}
```

- [ ] **Step 3: Implement `FeedGroup`**

Create `Yana/Models/FeedGroup.swift`:

```swift
import Foundation
import SwiftData

@Model
final class FeedGroup {
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Feed.group)
    var feeds: [Feed] = []

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}
```

- [ ] **Step 4: Implement `Feed`** (overwrite `Yana/Models/Feed.swift`)

Replace the entire contents of `Yana/Models/Feed.swift` with:

```swift
import Foundation
import SwiftData

@Model
final class Feed {
    var name: String = ""
    /// Raw value of `AggregatorType`. Use the `type` computed property for typed access.
    var aggregatorType: String = AggregatorType.feedContent.rawValue
    var identifier: String = ""
    var dailyLimit: Int = 20
    var enabled: Bool = true
    var options: AggregatorOptions = AggregatorOptions.feedContent(FeedContentOptions())
    var lastFetchedAt: Date?
    var lastError: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var group: FeedGroup?

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article] = []

    /// Typed accessor for `aggregatorType`.
    var type: AggregatorType {
        get { AggregatorType(rawValue: aggregatorType) ?? .feedContent }
        set { aggregatorType = newValue.rawValue }
    }

    init(
        name: String,
        aggregatorType: AggregatorType,
        identifier: String,
        dailyLimit: Int = 20,
        enabled: Bool = true,
        options: AggregatorOptions? = nil
    ) {
        self.name = name
        self.aggregatorType = aggregatorType.rawValue
        self.identifier = identifier
        self.dailyLimit = dailyLimit
        self.enabled = enabled
        self.options = options ?? aggregatorType.defaultOptions
        self.createdAt = .now
        self.updatedAt = .now
    }
}
```

- [ ] **Step 5: Implement `Article`** (overwrite `Yana/Models/Article.swift`)

Replace the entire contents of `Yana/Models/Article.swift` with:

```swift
import Foundation
import SwiftData

@Model
final class Article {
    var title: String = ""
    /// URL or external id; dedup key within a feed.
    var identifier: String = ""
    var url: String = ""
    var rawContent: String = ""
    var content: String = ""
    var date: Date = Date.now
    var read: Bool = false
    var starred: Bool = false
    var author: String = ""
    var iconURL: String?
    var createdAt: Date = Date.now

    var feed: Feed?

    init(
        title: String,
        identifier: String,
        url: String,
        rawContent: String = "",
        content: String = "",
        date: Date = .now,
        read: Bool = false,
        starred: Bool = false,
        author: String = "",
        iconURL: String? = nil
    ) {
        self.title = title
        self.identifier = identifier
        self.url = url
        self.rawContent = rawContent
        self.content = content
        self.date = date
        self.read = read
        self.starred = starred
        self.author = author
        self.iconURL = iconURL
        self.createdAt = .now
    }
}
```

- [ ] **Step 6: Verify (build deferred to Task 7)**

The model tests cannot run standalone because the app target still references the deleted
`APIClient`/`APIModels` and the old structs via `AppState` and the views. Proceed directly
to Task 7, which rewires those. The model tests are run at the end of Task 7.

- [ ] **Step 7: Commit (deferred to Task 7)**

Do not commit yet — the build is red until Task 7. Commit Tasks 6 and 7 together.

---

## Task 7: Rewire app shell (AppState, YanaApp, ContentView, views, Constants)

**Files:**
- Modify: `Yana/Models/AppState.swift` (full rewrite)
- Modify: `Yana/YanaApp.swift`
- Modify: `Yana/ContentView.swift` (full rewrite)
- Modify: `Yana/Views/ArticleReaderView.swift`
- Modify: `Yana/Views/SettingsView.swift` (full rewrite)
- Modify: `Yana/Utilities/Constants.swift`
- Modify: `YanaTests/YanaTests.swift`

- [ ] **Step 1: Rewrite `AppState`**

Replace the entire contents of `Yana/Models/AppState.swift` with:

```swift
import Foundation

@MainActor
@Observable
final class AppState {
    /// What the reader is currently showing.
    enum Scope: Equatable {
        case allUnread
        case starred
    }

    var scope: Scope = .allUnread
    var currentIndex: Int = 0
    var isUpdating = false
    var errorMessage: String?
    var showSettings = false
}
```

- [ ] **Step 2: Rewrite `YanaApp` to create the ModelContainer**

Replace the entire contents of `Yana/YanaApp.swift` with:

```swift
import SwiftData
import SwiftUI

@main
struct YanaApp: App {
    @State private var appState = AppState()

    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Feed.self, FeedGroup.self, Article.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 3: Rewrite `ContentView` (drop the auth gate and LoginView)**

Replace the entire contents of `Yana/ContentView.swift` with:

```swift
import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        ArticleReaderView(appState: appState)
    }
}
```

- [ ] **Step 4: Rewrite `ArticleReaderView` to read from SwiftData**

Replace the entire contents of `Yana/Views/ArticleReaderView.swift` with:

```swift
import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Query(
        filter: #Predicate<Article> { !$0.read },
        sort: \Article.date,
        order: .reverse
    ) private var articles: [Article]

    @State private var dragOffset: CGFloat = 0
    @State private var shareItem: URL?

    private var currentArticle: Article? {
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else {
            return nil
        }
        return articles[appState.currentIndex]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let article = currentArticle {
                    articleContent(article)
                        .offset(x: dragOffset)
                        .gesture(swipeGesture)
                        .animation(.interactiveSpring, value: dragOffset)
                } else {
                    ContentUnavailableView {
                        Label("All Caught Up", systemImage: "checkmark.circle")
                    } description: {
                        Text("No unread articles. Add feeds in Settings.")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $appState.showSettings) {
                SettingsView(appState: appState)
            }
            .sheet(item: $shareItem) { url in
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - Article Content

    @ViewBuilder
    private func articleContent(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let feedTitle = article.feed?.name, !feedTitle.isEmpty {
                        Text(feedTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.accent)
                    }

                    if !article.author.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(article.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(article.date, style: .relative)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ArticleWebView(htmlContent: article.content)
                    .frame(minHeight: 400)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(article)
        }
    }

    private func bottomBar(_ article: Article) -> some View {
        HStack {
            Spacer()
            if let url = URL(string: article.url) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button {
                    shareItem = url
                } label: {
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

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 100
                if value.translation.width < -threshold {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = -UIScreen.main.bounds.width
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        markCurrentAsReadAndAdvance()
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold && appState.currentIndex > 0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = UIScreen.main.bounds.width
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex -= 1
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.interactiveSpring) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// Mark the current article read. The `@Query` (unread-only) drops it, so the next
    /// unread article shifts into the current index automatically; clamp the index.
    private func markCurrentAsReadAndAdvance() {
        guard let article = currentArticle else { return }
        article.read = true
        if appState.currentIndex >= articles.count - 1 {
            appState.currentIndex = max(0, articles.count - 2)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - URL + Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
```

- [ ] **Step 5: Rewrite `SettingsView` to a minimal placeholder hub**

Replace the entire contents of `Yana/Views/SettingsView.swift` with:

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Feed configuration, groups, and API keys are coming next.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Yana")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
```

- [ ] **Step 6: Remove the Google Reader paths from Constants**

Replace the entire contents of `Yana/Utilities/Constants.swift` with:

```swift
import Foundation

enum AppConstants {
    static let bundleID = "de.fa-krug.Yana"
    static let keychainService = "de.fa-krug.Yana"
}
```

- [ ] **Step 7: Update the existing app-state test**

Replace the entire contents of `YanaTests/YanaTests.swift` with:

```swift
import Testing
@testable import Yana

@MainActor
@Suite("Yana Tests")
struct YanaTests {
    @Test func appStateDefaults() {
        let state = AppState()
        #expect(state.scope == .allUnread)
        #expect(state.currentIndex == 0)
        #expect(state.isUpdating == false)
        #expect(state.showSettings == false)
    }
}
```

- [ ] **Step 8: Regenerate the project and build**

Run:
```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Run the full test bundle**

Run:
```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests test
```
Expected: PASS — all suites (`AggregatorType`, `AggregatorOptions`, `AggregatorRegistry`, `AppSettings`, `SwiftData Models`, `Yana Tests`).

- [ ] **Step 10: Commit Tasks 6 and 7 together**

```bash
git add -A
git commit -m "feat: SwiftData models and local-only app shell

Replace server-client foundation with SwiftData Feed/FeedGroup/Article
models and rewire AppState, YanaApp, ContentView, and views to a
local-only aggregator shell. Remove APIClient, APIModels, GReader
constants, and the login/auth flow."
```

---

## Self-Review

**Spec coverage:**
- Three SwiftData `@Model`s (Feed/FeedGroup/Article) → Task 6 ✓
- Typed `AggregatorOptions` enum (option A, no blob) → Task 3 ✓
- `AggregatorType` with full-parity cases + metadata → Task 2 ✓
- `Aggregator` protocol, `AggregatedArticle`, empty `AggregatorRegistry` → Task 4 ✓
- `AppSettings` (UserDefaults) + Keychain repurposed for API keys → Task 5 ✓
- Thin `AppState`; `ModelContainer` in `YanaApp`; auth gate dropped → Task 7 ✓
- Delete `APIClient`, `APIModels`, old structs, GReader paths, login UI → Tasks 6 & 7 ✓
- Keep `ArticleReaderView`/`ArticleWebView` (rewired to SwiftData) → Task 7 ✓
- Docs rewrite → Task 1 ✓
- Deferred to later plans (correctly out of scope here): config hub UI (Phase 2),
  concrete aggregators + `AggregationService` + force-update + background refresh (Phase 3),
  scope selector with feed/group cases (Phase 2).

**Placeholder scan:** No "TBD"/"add error handling"-style placeholders; all code is complete.
The only `nil`-returning body (`AggregatorRegistry.makeAggregator`) is an intentional,
tested Phase-1 stub, documented as such.

**Type consistency:** `AggregatorType`, `AggregatorOptions` cases/structs, `AggregatorAPIKey`,
`AggregatorIdentifierKind`, `Feed.type`, `Article` initializer signature, `AppSettings`
properties, and `KeychainService.APIKeyItem` are referenced consistently across tasks and
tests. `Feed(name:aggregatorType:identifier:...)` and `Article(title:identifier:url:...)`
initializers match every call site in the tests.

## Build-Order Caveat (important)

Tasks 2+3 form one compiling unit (commit together — done in Task 3). Tasks 6+7 form one
compiling unit (the build is intentionally red between them; commit together — done in
Task 7). Every other task is independently green. If executing with per-task review gates,
treat 2–3 and 6–7 as paired.
