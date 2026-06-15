# Local Aggregator Phase 2 (Configuration UI) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the configuration hub (Feeds, Tags, Settings) and the endless-timeline reader on the existing SwiftData foundation, wired to a no-op `AggregationService` stub that Phase 3 fills in.

**Architecture:** Pure SwiftUI + SwiftData. Phase 1 models are revised first (drop `FeedGroup`, drop read/starred state, introduce a per-feed `Tag` system snapshotted onto articles, split managed options into per-scraper structs, expand `AppSettings` to full server parity). Then logic helpers (tag filter, timeline anchor, feed-editor view model), the stub service, and the views. Testable logic is extracted into pure functions/types; views are verified by building.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-06-15-local-aggregator-design.md`
**Roadmap:** `docs/superpowers/plans/2026-06-15-local-aggregator-phase2-ui.md`

**Conventions for every task:**
- Tests live in `YanaTests/` (host-app target — `@testable import Yana` works).
- After adding/removing **files**, run `xcodegen generate` before building (XcodeGen includes sources by folder).
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- Build-only (for view tasks): `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- All user-facing strings use `String(localized:)` / `LocalizedStringKey`.

---

## Task 1: `Tag` model + container registration + seeding

**Files:**
- Create: `Yana/Models/Tag.swift`
- Delete: `Yana/Models/FeedGroup.swift`
- Modify: `Yana/YanaApp.swift`
- Test: `YanaTests/TagTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/TagTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Tag")
struct TagTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func seedsStarredOnceAndIsIdempotent() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        Tag.ensureBuiltIns(in: context)
        try context.save()

        let starred = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn }))
        #expect(starred.count == 1)
        #expect(starred.first?.name == Tag.starredName)
    }

    @Test func feedTagsAreSnapshotIntoArticleTags() throws {
        let context = try makeContext()
        let tag = Tag(name: "Tech")
        let feed = Feed(name: "Heise", aggregatorType: .heise, identifier: "https://heise.de")
        feed.tags = [tag]
        let article = Article(title: "P", identifier: "p1", url: "https://heise.de/1")
        article.feed = feed
        article.tags = feed.tags
        context.insert(tag); context.insert(feed); context.insert(article)
        try context.save()

        let reloaded = try context.fetch(FetchDescriptor<Article>()).first
        #expect(reloaded?.tags.map(\.name) == ["Tech"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `Tag` does not exist / compile error.

- [ ] **Step 3: Create the `Tag` model**

Create `Yana/Models/Tag.swift`:

```swift
import Foundation
import SwiftData

@Model
final class Tag {
    var name: String = ""
    var colorHex: String?
    /// True only for the seeded, locked "Starred" tag.
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(inverse: \Feed.tags)
    var feeds: [Feed] = []

    @Relationship(inverse: \Article.tags)
    var articles: [Article] = []

    init(name: String, colorHex: String? = nil, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    /// The canonical name of the built-in Starred tag.
    static let starredName = "Starred"

    /// Insert the built-in Starred tag if it isn't already present. Idempotent.
    static func ensureBuiltIns(in context: ModelContext) {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }
        context.insert(Tag(name: starredName, colorHex: "#F5C518", isBuiltIn: true, sortOrder: -1))
    }
}
```

> Note: `Feed.tags` and `Article.tags` are added in Task 2; this file references them, so Tasks 1 and 2 are compiled together. If implementing strictly one task at a time, apply Task 2's model edits before building.

- [ ] **Step 4: Delete `FeedGroup` and update the container**

Delete `Yana/Models/FeedGroup.swift`.

In `Yana/YanaApp.swift`, replace the container and seed Starred on launch:

```swift
import SwiftData
import SwiftUI

@main
struct YanaApp: App {
    @State private var appState = AppState()

    let container: ModelContainer = {
        do {
            let container = try ModelContainer(for: Feed.self, Tag.self, Article.self)
            Tag.ensureBuiltIns(in: container.mainContext)
            try? container.mainContext.save()
            return container
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

- [ ] **Step 5: Run `xcodegen generate`** (a file was deleted)

Run: `xcodegen generate`
Expected: "Created project at Yana.xcodeproj"

(Proceed to Task 2 before building — `Tag` references `Feed.tags`/`Article.tags`.)

---

## Task 2: Retag `Feed` and `Article` (drop groups + read state)

**Files:**
- Modify: `Yana/Models/Feed.swift`
- Modify: `Yana/Models/Article.swift`
- Modify: `YanaTests/ModelTests.swift`
- Test: `YanaTests/ArticleStarredTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleStarredTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Article starred-as-tag")
struct ArticleStarredTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func starringAddsBuiltInTagUnstarringRemovesIt() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        try context.save()
        let starred = try #require(try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })).first)

        let article = Article(title: "P", identifier: "p1", url: "https://x.com/1")
        context.insert(article)

        #expect(article.isStarred == false)
        article.setStarred(true, using: starred)
        #expect(article.isStarred == true)
        article.setStarred(false, using: starred)
        #expect(article.isStarred == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `setStarred`/`isStarred` undefined; `Article.read`/`Feed.group` references may also fail to compile.

- [ ] **Step 3: Update `Feed`**

In `Yana/Models/Feed.swift`, remove the `group` property and add `tags`:

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

    /// Template tags applied (as a snapshot) to this feed's articles at import time.
    var tags: [Tag] = []

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article] = []

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

- [ ] **Step 4: Update `Article`**

Replace `Yana/Models/Article.swift`:

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
    var author: String = ""
    var iconURL: String?
    var createdAt: Date = Date.now

    /// Snapshot of the feed's tags at import, plus the built-in Starred tag when starred.
    var tags: [Tag] = []

    var feed: Feed?

    init(
        title: String,
        identifier: String,
        url: String,
        rawContent: String = "",
        content: String = "",
        date: Date = .now,
        author: String = "",
        iconURL: String? = nil
    ) {
        self.title = title
        self.identifier = identifier
        self.url = url
        self.rawContent = rawContent
        self.content = content
        self.date = date
        self.author = author
        self.iconURL = iconURL
        self.createdAt = .now
    }

    /// Starred state is expressed purely as membership of the built-in tag.
    var isStarred: Bool { tags.contains { $0.isBuiltIn } }

    /// Add or remove the built-in Starred tag.
    func setStarred(_ starred: Bool, using starredTag: Tag) {
        if starred {
            if !tags.contains(where: { $0.id == starredTag.id }) { tags.append(starredTag) }
        } else {
            tags.removeAll { $0.isBuiltIn }
        }
    }
}
```

- [ ] **Step 5: Fix the existing `ModelTests`**

In `YanaTests/ModelTests.swift`: (a) change `makeContext` to register `Tag.self` instead of `FeedGroup.self`; (b) replace the `groupFeedRelationship` test with a tag relationship test. The cascade-delete and typed-options tests stay (the `Article(...)` call there already omits read/starred). New `makeContext` and replacement test:

```swift
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Feed.self, Tag.self, Article.self,
            configurations: config
        )
        return ModelContext(container)
    }
```

Replace `groupFeedRelationship()` with:

```swift
    @Test func feedTagRelationship() throws {
        let context = try makeContext()
        let tag = Tag(name: "Tech")
        let feed = Feed(name: "Heise", aggregatorType: .heise, identifier: "https://heise.de")
        feed.tags = [tag]
        context.insert(tag)
        context.insert(feed)
        try context.save()

        let reloadedTag = try context.fetch(FetchDescriptor<Tag>()).first
        #expect(reloadedTag?.feeds.count == 1)
        #expect(reloadedTag?.feeds.first?.name == "Heise")
    }
```

- [ ] **Step 6: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (Tag, ArticleStarred, Model suites green). The reader still references `Article.read`; if the build fails there, it is fixed in Task 11 — to keep this task green, temporarily that reference must compile. **Apply the minimal reader fix now:** in `Yana/Views/ArticleReaderView.swift` change the `@Query` filter to `sort: \Article.date, order: .reverse` with no predicate, and delete the `markCurrentAsReadAndAdvance` body's `article.read = true` (replace the method body with `// replaced by timeline in Task 11`). Full reader rewrite lands in Task 11.

```swift
    @Query(sort: \Article.date, order: .reverse) private var articles: [Article]
```

```swift
    private func markCurrentAsReadAndAdvance() {
        // Timeline reader (Task 11) replaces read-based advancing.
        guard appState.currentIndex < articles.count - 1 else { return }
        appState.currentIndex += 1
    }
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: replace feed groups + read state with per-feed tags"
```

---

## Task 3: Per-scraper aggregator options

**Files:**
- Modify: `Yana/Models/AggregatorOptions.swift`
- Modify: `Yana/Aggregators/AggregatorType.swift`
- Modify: `YanaTests/AggregatorOptionsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `YanaTests/AggregatorOptionsTests.swift` (inside the suite):

```swift
    @Test func redditHasMinAgeHours() {
        #expect(RedditOptions().minAgeHours == 48)
    }

    @Test func oglafHasConvertToBase64() throws {
        var opts = OglafOptions()
        opts.convertToBase64 = false
        let decoded = try roundTrip(.oglaf(opts))
        guard case .oglaf(let out) = decoded else { Issue.record("wrong case"); return }
        #expect(out.convertToBase64 == false)
        #expect(out.showAltText == true)
    }

    @Test func heiseRoundTrip() throws {
        var opts = HeiseOptions()
        opts.maxComments = 9
        let decoded = try roundTrip(.heise(opts))
        guard case .heise(let out) = decoded else { Issue.record("wrong case"); return }
        #expect(out.maxComments == 9)
        #expect(out.includeComments == true)
    }

    @Test func defaultOptionsMatchType() {
        if case .heise = AggregatorType.heise.defaultOptions {} else { Issue.record("heise default") }
        if case .tagesschau = AggregatorType.tagesschau.defaultOptions {} else { Issue.record("tagesschau default") }
        if case .meinMmo = AggregatorType.meinMmo.defaultOptions {} else { Issue.record("meinMmo default") }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `OglafOptions`, `HeiseOptions`, `RedditOptions.minAgeHours`, `.oglaf` case undefined.

- [ ] **Step 3: Rewrite `AggregatorOptions.swift`**

Replace `Yana/Models/AggregatorOptions.swift`:

```swift
import Foundation

/// AI post-processing toggles, shared by every aggregator.
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

/// `feed_content` has no extra options on the server — AI only.
struct FeedContentOptions: Codable, Sendable, Equatable {
    var ai = AIOptions()
}

struct RedditOptions: Codable, Sendable, Equatable {
    var subredditSort = "hot"   // hot | new | top | rising
    var minComments = 5
    var commentLimit = 10
    var includeHeaderImage = true
    var minAgeHours = 48        // 0–168
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

struct HeiseOptions: Codable, Sendable, Equatable {
    var includeComments = true
    var maxComments = 5
    var ai = AIOptions()
}

struct MerkurOptions: Codable, Sendable, Equatable {
    var removeEmptyElements = true
    var ai = AIOptions()
}

struct TagesschauOptions: Codable, Sendable, Equatable {
    var skipLivestreams = true
    var skipVideos = true
    var ai = AIOptions()
}

struct ExplosmOptions: Codable, Sendable, Equatable {
    var showAltText = true
    var ai = AIOptions()
}

struct DarkLegacyOptions: Codable, Sendable, Equatable {
    var showAltText = true
    var ai = AIOptions()
}

struct CaschysBlogOptions: Codable, Sendable, Equatable {
    var skipAds = true
    var ai = AIOptions()
}

struct MactechnewsOptions: Codable, Sendable, Equatable {
    var combinePages = true
    var includeComments = true
    var maxComments = 5
    var ai = AIOptions()
}

struct OglafOptions: Codable, Sendable, Equatable {
    var showAltText = true
    var convertToBase64 = true
    var ai = AIOptions()
}

struct MeinMmoOptions: Codable, Sendable, Equatable {
    var combinePages = true
    var ai = AIOptions()
}

/// Typed per-feed aggregator configuration. One case per `AggregatorType`.
enum AggregatorOptions: Codable, Sendable, Equatable {
    case fullWebsite(WebsiteOptions)
    case feedContent(FeedContentOptions)
    case reddit(RedditOptions)
    case youtube(YouTubeOptions)
    case podcast(PodcastOptions)
    case heise(HeiseOptions)
    case merkur(MerkurOptions)
    case tagesschau(TagesschauOptions)
    case explosm(ExplosmOptions)
    case darkLegacy(DarkLegacyOptions)
    case caschysBlog(CaschysBlogOptions)
    case mactechnews(MactechnewsOptions)
    case oglaf(OglafOptions)
    case meinMmo(MeinMmoOptions)

    /// The AI block, regardless of which case is active.
    var ai: AIOptions {
        switch self {
        case .fullWebsite(let o): o.ai
        case .feedContent(let o): o.ai
        case .reddit(let o): o.ai
        case .youtube(let o): o.ai
        case .podcast(let o): o.ai
        case .heise(let o): o.ai
        case .merkur(let o): o.ai
        case .tagesschau(let o): o.ai
        case .explosm(let o): o.ai
        case .darkLegacy(let o): o.ai
        case .caschysBlog(let o): o.ai
        case .mactechnews(let o): o.ai
        case .oglaf(let o): o.ai
        case .meinMmo(let o): o.ai
        }
    }
}
```

- [ ] **Step 4: Update `AggregatorType.defaultOptions`**

In `Yana/Aggregators/AggregatorType.swift`, replace the `defaultOptions` switch:

```swift
    /// The default typed options for a freshly created feed of this type.
    var defaultOptions: AggregatorOptions {
        switch self {
        case .fullWebsite: .fullWebsite(WebsiteOptions())
        case .feedContent: .feedContent(FeedContentOptions())
        case .reddit: .reddit(RedditOptions())
        case .youtube: .youtube(YouTubeOptions())
        case .podcast: .podcast(PodcastOptions())
        case .heise: .heise(HeiseOptions())
        case .merkur: .merkur(MerkurOptions())
        case .tagesschau: .tagesschau(TagesschauOptions())
        case .explosm: .explosm(ExplosmOptions())
        case .darkLegacy: .darkLegacy(DarkLegacyOptions())
        case .caschysBlog: .caschysBlog(CaschysBlogOptions())
        case .mactechnews: .mactechnews(MactechnewsOptions())
        case .oglaf: .oglaf(OglafOptions())
        case .meinMmo: .meinMmo(MeinMmoOptions())
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: split managed options into per-scraper option structs"
```

---

## Task 4: Expand `AppSettings` to full server parity + model lists

**Files:**
- Modify: `Yana/Models/AppSettings.swift`
- Modify: `YanaTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `YanaTests/AppSettingsTests.swift` (inside the suite):

```swift
    @Test func aiKnobsHaveServerParityDefaults() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.aiTemperature == 0.3)
        #expect(s.aiMaxTokens == 2000)
        #expect(s.aiRequestDelay == 2)
        #expect(s.redditUserAgent == "Yana/1.0")
        #expect(s.openaiAPIURL == "https://api.openai.com/v1")
        #expect(s.openaiModel == "gpt-4o-mini")
    }

    @Test func providerModelListsAreNonEmpty() {
        #expect(AIProvider.openai.models.contains("gpt-4o-mini"))
        #expect(!AIProvider.anthropic.models.isEmpty)
        #expect(!AIProvider.gemini.models.isEmpty)
        #expect(AIProvider.none.models.isEmpty)
    }

    @Test func newFieldsPersist() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        s.aiTemperature = 0.7
        s.anthropicModel = "claude-sonnet-4-6"
        s.redditEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiTemperature == 0.7)
        #expect(reloaded.anthropicModel == "claude-sonnet-4-6")
        #expect(reloaded.redditEnabled == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — new properties and `AIProvider.models` undefined.

- [ ] **Step 3: Rewrite `AppSettings.swift`**

Replace `Yana/Models/AppSettings.swift`:

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

    /// iOS-maintained current model lists (the server's choice lists are stale).
    /// Update these as providers ship new models.
    var models: [String] {
        switch self {
        case .none: []
        case .openai: ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini", "o3"]
        case .anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        }
    }

    var defaultModel: String { models.first ?? "" }
}

/// Non-secret user preferences, backed by UserDefaults. Secrets live in `KeychainService`.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.retentionDays: 30,
            Key.backgroundInterval: 1800.0,
            Key.redditUserAgent: "Yana/1.0",
            Key.openaiAPIURL: "https://api.openai.com/v1",
            Key.openaiModel: "gpt-4o-mini",
            Key.anthropicModel: "claude-haiku-4-5-20251001",
            Key.geminiModel: "gemini-2.5-flash",
            Key.aiTemperature: 0.3,
            Key.aiMaxTokens: 2000,
            Key.aiMaxPromptLength: 500,
            Key.aiDefaultDailyLimit: 200,
            Key.aiDefaultMonthlyLimit: 2000,
            Key.aiRequestTimeout: 120,
            Key.aiMaxRetries: 3,
            Key.aiRetryDelay: 2,
            Key.aiRequestDelay: 2,
            Key.includeUntagged: true,
        ])
    }

    private enum Key {
        static let activeAIProvider = "settings.activeAIProvider"
        static let retentionDays = "settings.retentionDays"
        static let backgroundInterval = "settings.backgroundInterval"
        // Sources
        static let redditEnabled = "settings.redditEnabled"
        static let redditUserAgent = "settings.redditUserAgent"
        static let youtubeEnabled = "settings.youtubeEnabled"
        // Providers
        static let openaiEnabled = "settings.openaiEnabled"
        static let anthropicEnabled = "settings.anthropicEnabled"
        static let geminiEnabled = "settings.geminiEnabled"
        static let openaiAPIURL = "settings.openaiAPIURL"
        static let openaiModel = "settings.openaiModel"
        static let anthropicModel = "settings.anthropicModel"
        static let geminiModel = "settings.geminiModel"
        // AI knobs
        static let aiTemperature = "settings.aiTemperature"
        static let aiMaxTokens = "settings.aiMaxTokens"
        static let aiMaxPromptLength = "settings.aiMaxPromptLength"
        static let aiDefaultDailyLimit = "settings.aiDefaultDailyLimit"
        static let aiDefaultMonthlyLimit = "settings.aiDefaultMonthlyLimit"
        static let aiRequestTimeout = "settings.aiRequestTimeout"
        static let aiMaxRetries = "settings.aiMaxRetries"
        static let aiRetryDelay = "settings.aiRetryDelay"
        static let aiRequestDelay = "settings.aiRequestDelay"
        // Timeline filter
        static let disabledTagNames = "settings.disabledTagNames"
        static let includeUntagged = "settings.includeUntagged"
        // Timeline position
        static let timelineAnchorIdentifier = "settings.timelineAnchorIdentifier"
    }

    var activeAIProvider: AIProvider {
        get {
            guard let raw = defaults.string(forKey: Key.activeAIProvider),
                  let provider = AIProvider(rawValue: raw) else { return .none }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.activeAIProvider) }
    }

    var retentionDays: Int {
        get { defaults.integer(forKey: Key.retentionDays) }
        set { defaults.set(newValue, forKey: Key.retentionDays) }
    }

    var backgroundInterval: TimeInterval {
        get { defaults.double(forKey: Key.backgroundInterval) }
        set { defaults.set(newValue, forKey: Key.backgroundInterval) }
    }

    // MARK: Sources
    var redditEnabled: Bool {
        get { defaults.bool(forKey: Key.redditEnabled) }
        set { defaults.set(newValue, forKey: Key.redditEnabled) }
    }
    var redditUserAgent: String {
        get { defaults.string(forKey: Key.redditUserAgent) ?? "Yana/1.0" }
        set { defaults.set(newValue, forKey: Key.redditUserAgent) }
    }
    var youtubeEnabled: Bool {
        get { defaults.bool(forKey: Key.youtubeEnabled) }
        set { defaults.set(newValue, forKey: Key.youtubeEnabled) }
    }

    // MARK: Providers
    var openaiEnabled: Bool {
        get { defaults.bool(forKey: Key.openaiEnabled) }
        set { defaults.set(newValue, forKey: Key.openaiEnabled) }
    }
    var anthropicEnabled: Bool {
        get { defaults.bool(forKey: Key.anthropicEnabled) }
        set { defaults.set(newValue, forKey: Key.anthropicEnabled) }
    }
    var geminiEnabled: Bool {
        get { defaults.bool(forKey: Key.geminiEnabled) }
        set { defaults.set(newValue, forKey: Key.geminiEnabled) }
    }
    var openaiAPIURL: String {
        get { defaults.string(forKey: Key.openaiAPIURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Key.openaiAPIURL) }
    }
    var openaiModel: String {
        get { defaults.string(forKey: Key.openaiModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Key.openaiModel) }
    }
    var anthropicModel: String {
        get { defaults.string(forKey: Key.anthropicModel) ?? "claude-haiku-4-5-20251001" }
        set { defaults.set(newValue, forKey: Key.anthropicModel) }
    }
    var geminiModel: String {
        get { defaults.string(forKey: Key.geminiModel) ?? "gemini-2.5-flash" }
        set { defaults.set(newValue, forKey: Key.geminiModel) }
    }

    // MARK: AI knobs
    var aiTemperature: Double {
        get { defaults.double(forKey: Key.aiTemperature) }
        set { defaults.set(newValue, forKey: Key.aiTemperature) }
    }
    var aiMaxTokens: Int {
        get { defaults.integer(forKey: Key.aiMaxTokens) }
        set { defaults.set(newValue, forKey: Key.aiMaxTokens) }
    }
    var aiMaxPromptLength: Int {
        get { defaults.integer(forKey: Key.aiMaxPromptLength) }
        set { defaults.set(newValue, forKey: Key.aiMaxPromptLength) }
    }
    var aiDefaultDailyLimit: Int {
        get { defaults.integer(forKey: Key.aiDefaultDailyLimit) }
        set { defaults.set(newValue, forKey: Key.aiDefaultDailyLimit) }
    }
    var aiDefaultMonthlyLimit: Int {
        get { defaults.integer(forKey: Key.aiDefaultMonthlyLimit) }
        set { defaults.set(newValue, forKey: Key.aiDefaultMonthlyLimit) }
    }
    var aiRequestTimeout: Int {
        get { defaults.integer(forKey: Key.aiRequestTimeout) }
        set { defaults.set(newValue, forKey: Key.aiRequestTimeout) }
    }
    var aiMaxRetries: Int {
        get { defaults.integer(forKey: Key.aiMaxRetries) }
        set { defaults.set(newValue, forKey: Key.aiMaxRetries) }
    }
    var aiRetryDelay: Int {
        get { defaults.integer(forKey: Key.aiRetryDelay) }
        set { defaults.set(newValue, forKey: Key.aiRetryDelay) }
    }
    var aiRequestDelay: Int {
        get { defaults.integer(forKey: Key.aiRequestDelay) }
        set { defaults.set(newValue, forKey: Key.aiRequestDelay) }
    }

    // MARK: Timeline filter
    /// Names of tags currently toggled OFF in the filter. Empty = all active.
    var disabledTagNames: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledTagNames) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.disabledTagNames) }
    }
    var includeUntagged: Bool {
        get { defaults.bool(forKey: Key.includeUntagged) }
        set { defaults.set(newValue, forKey: Key.includeUntagged) }
    }

    // MARK: Timeline position
    var timelineAnchorIdentifier: String? {
        get { defaults.string(forKey: Key.timelineAnchorIdentifier) }
        set { defaults.set(newValue, forKey: Key.timelineAnchorIdentifier) }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: expand AppSettings to full server parity + provider model lists"
```

---

## Task 5: Pure logic helpers — tag filter + timeline anchor

**Files:**
- Create: `Yana/Utilities/TimelineFiltering.swift`
- Test: `YanaTests/TimelineFilteringTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/TimelineFilteringTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Timeline filtering + anchor")
struct TimelineFilteringTests {
    private func article(_ id: String, tags: [Tag]) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.tags = tags
        return a
    }

    @Test func untaggedRespectsToggle() {
        let a = article("a", tags: [])
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: true).count == 1)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: false).isEmpty)
    }

    @Test func showsArticleWithAnyActiveTag() {
        let tech = Tag(name: "Tech")
        let fun = Tag(name: "Fun")
        let a = article("a", tags: [tech, fun])
        // Tech disabled but Fun active -> still shown.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech"], includeUntagged: true).count == 1)
        // Both disabled -> hidden.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech", "Fun"], includeUntagged: true).isEmpty)
    }

    @Test func anchorResolvesToIndexOrZero() {
        let a = article("a", tags: [])
        let b = article("b", tags: [])
        let list = [a, b]
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        #expect(TimelineAnchor.index(for: "missing", in: list) == 0)
        #expect(TimelineAnchor.index(for: nil, in: list) == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `TagFilter` / `TimelineAnchor` undefined.

- [ ] **Step 3: Create the helpers**

Create `Yana/Utilities/TimelineFiltering.swift`:

```swift
import Foundation

/// Filters the timeline by active tags. OR semantics: an article is shown if it has at
/// least one tag that is *not* disabled. Untagged articles are shown only when
/// `includeUntagged` is true.
enum TagFilter {
    static func apply(to articles: [Article], disabledTagNames: Set<String>, includeUntagged: Bool) -> [Article] {
        articles.filter { article in
            let names = Set(article.tags.map(\.name))
            if names.isEmpty { return includeUntagged }
            return !names.isSubset(of: disabledTagNames)
        }
    }
}

/// Resolves the persisted timeline anchor (an article `identifier`) to an index in the
/// currently displayed list, falling back to 0 (newest) when it is missing.
enum TimelineAnchor {
    static func index(for identifier: String?, in articles: [Article]) -> Int {
        guard let identifier,
              let idx = articles.firstIndex(where: { $0.identifier == identifier }) else { return 0 }
        return idx
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: tag filter + timeline anchor pure helpers"
```

---

## Task 6: `AggregationService` stub

**Files:**
- Create: `Yana/Services/AggregationService.swift`
- Test: `YanaTests/AggregationServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregationServiceTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService stub")
struct AggregationServiceTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func updateAllTouchesEnabledFeedsAndClearsFlag() async throws {
        let context = try makeContext()
        let enabled = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://a.com/feed")
        let disabled = Feed(name: "B", aggregatorType: .feedContent, identifier: "https://b.com/feed", enabled: false)
        context.insert(enabled); context.insert(disabled)
        try context.save()

        let service = AggregationService(context: context)
        await service.updateAll()

        #expect(service.isUpdating == false)
        #expect(enabled.lastFetchedAt != nil)
        #expect(disabled.lastFetchedAt == nil)
    }

    @Test func updateFeedTouchesThatFeed() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://a.com/feed")
        context.insert(feed)
        try context.save()

        let service = AggregationService(context: context)
        await service.update(feed: feed)
        #expect(feed.lastFetchedAt != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `AggregationService` undefined.

- [ ] **Step 3: Create the stub**

Create `Yana/Services/AggregationService.swift`:

```swift
import Foundation
import SwiftData

/// Phase 2 stub. The public API the UI wires to; Phase 3 replaces the bodies with real
/// fetching/parsing/upsert. For now it only flips `isUpdating` and touches `lastFetchedAt`.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Update all enabled feeds.
    func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = (try? context.fetch(descriptor)) ?? []
        for feed in feeds { feed.lastFetchedAt = .now }
        try? context.save()
    }

    /// Update a single feed.
    func update(feed: Feed) async {
        isUpdating = true
        defer { isUpdating = false }
        feed.lastFetchedAt = .now
        try? context.save()
    }

    /// Re-fetch and re-process a single article. No-op in Phase 2.
    func update(article: Article) async {
        isUpdating = true
        defer { isUpdating = false }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add AggregationService stub"
```

---

## Task 7: `FeedEditorModel` (enum↔form bridge — the risky logic)

**Files:**
- Create: `Yana/Views/Config/FeedEditorModel.swift`
- Test: `YanaTests/FeedEditorModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedEditorModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("FeedEditorModel")
struct FeedEditorModelTests {
    @Test func newModelStartsWithDefaultsAndIsInvalidWithoutName() {
        let model = FeedEditorModel(feed: nil)
        #expect(model.name.isEmpty)
        #expect(model.isValid == false)
        model.name = "Heise"
        model.type = .heise
        model.identifier = "https://heise.de"
        #expect(model.isValid == true)
    }

    @Test func identifierNotRequiredForNoneKind() {
        let model = FeedEditorModel(feed: nil)
        model.name = "Oglaf"
        model.changeType(.oglaf) // identifierKind == .none
        #expect(model.identifier.isEmpty)
        #expect(model.isValid == true)
    }

    @Test func changingTypeResetsOptionsToDefault() {
        let model = FeedEditorModel(feed: nil)
        model.changeType(.reddit)
        guard case .reddit = model.options else { Issue.record("expected reddit options"); return }
        model.changeType(.podcast)
        guard case .podcast = model.options else { Issue.record("expected podcast options"); return }
    }

    @Test func applyWritesFieldsAndMatchedTags() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        let tech = Tag(name: "Tech"); let fun = Tag(name: "Fun")
        context.insert(tech); context.insert(fun)

        let model = FeedEditorModel(feed: nil)
        model.name = "Heise"
        model.changeType(.heise)
        model.identifier = "https://heise.de"
        model.dailyLimit = 5
        model.selectedTagNames = ["Tech"]

        let feed = Feed(name: "", aggregatorType: .feedContent, identifier: "")
        model.apply(to: feed, availableTags: [tech, fun])

        #expect(feed.name == "Heise")
        #expect(feed.type == .heise)
        #expect(feed.dailyLimit == 5)
        #expect(feed.tags.map(\.name) == ["Tech"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `FeedEditorModel` undefined.

- [ ] **Step 3: Create the view model**

Create `Yana/Views/Config/FeedEditorModel.swift`:

```swift
import Foundation
import SwiftData

/// Decomposed, bindable editing state for a `Feed`. Holds a single `AggregatorOptions`
/// value (edited via the dynamic form); changing the type resets options to that type's
/// defaults. `apply(to:availableTags:)` writes the state back onto a `Feed`.
@MainActor
@Observable
final class FeedEditorModel {
    var name: String
    var type: AggregatorType
    var identifier: String
    var dailyLimit: Int
    var enabled: Bool
    var options: AggregatorOptions
    /// Tags chosen by name (resolved to `Tag` instances on apply).
    var selectedTagNames: Set<String>

    let isEditingExisting: Bool

    init(feed: Feed?) {
        if let feed {
            name = feed.name
            type = feed.type
            identifier = feed.identifier
            dailyLimit = feed.dailyLimit
            enabled = feed.enabled
            options = feed.options
            selectedTagNames = Set(feed.tags.map(\.name))
            isEditingExisting = true
        } else {
            name = ""
            type = .feedContent
            identifier = ""
            dailyLimit = 20
            enabled = true
            options = AggregatorType.feedContent.defaultOptions
            selectedTagNames = []
            isEditingExisting = false
        }
    }

    var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if type.identifierKind == .none { return true }
        return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func changeType(_ newType: AggregatorType) {
        type = newType
        options = newType.defaultOptions
    }

    func apply(to feed: Feed, availableTags: [Tag]) {
        feed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.type = type
        feed.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.dailyLimit = dailyLimit
        feed.enabled = enabled
        feed.options = options
        feed.tags = availableTags.filter { selectedTagNames.contains($0.name) }
        feed.updatedAt = .now
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: FeedEditorModel enum<->form bridge"
```

---

## Task 8: Config hub shell + `AggregatorOptionsForm` + `FeedEditorView`

**Files:**
- Create: `Yana/Views/Config/ConfigHubView.swift`
- Create: `Yana/Views/Config/AggregatorOptionsForm.swift`
- Create: `Yana/Views/Config/FeedEditorView.swift`
- Delete: `Yana/Views/SettingsView.swift`
- Modify: `Yana/Views/ArticleReaderView.swift` (point the sheet at `ConfigHubView`)

> Views in this task are verified by **building** (no unit tests). `FeedsView`, `TagsView`, and `SettingsScreenView` are referenced by `ConfigHubView` and created in Tasks 9–10; create lightweight versions here is unnecessary — instead, build after Task 10. To keep this task independently buildable, `ConfigHubView` links are added incrementally: include only the Feed editor path now and add Tags/Settings links in their tasks.

- [ ] **Step 1: Create `AggregatorOptionsForm`**

Create `Yana/Views/Config/AggregatorOptionsForm.swift`:

```swift
import SwiftUI

/// Renders the per-type options for the active `AggregatorOptions` case, plus the shared
/// AI block. Editing goes through case-specific bindings back into the bound enum.
struct AggregatorOptionsForm: View {
    @Binding var options: AggregatorOptions

    var body: some View {
        Group {
            switch options {
            case .fullWebsite(let o):
                websiteSection(o)
            case .feedContent:
                EmptyView() // AI only
            case .reddit(let o):
                redditSection(o)
            case .youtube(let o):
                youtubeSection(o)
            case .podcast(let o):
                podcastSection(o)
            case .heise(let o):
                heiseSection(o)
            case .merkur(let o):
                toggleSection("Merkur", isOn: o.removeEmptyElements,
                              label: "Remove Empty Elements") { var n = o; n.removeEmptyElements = $0; options = .merkur(n) }
            case .tagesschau(let o):
                tagesschauSection(o)
            case .explosm(let o):
                toggleSection("Explosm", isOn: o.showAltText, label: "Show Alt Text") {
                    var n = o; n.showAltText = $0; options = .explosm(n)
                }
            case .darkLegacy(let o):
                toggleSection("Dark Legacy", isOn: o.showAltText, label: "Show Alt Text") {
                    var n = o; n.showAltText = $0; options = .darkLegacy(n)
                }
            case .caschysBlog(let o):
                toggleSection("Caschy's Blog", isOn: o.skipAds, label: "Skip Advertisements") {
                    var n = o; n.skipAds = $0; options = .caschysBlog(n)
                }
            case .mactechnews(let o):
                mactechnewsSection(o)
            case .oglaf(let o):
                oglafSection(o)
            case .meinMmo(let o):
                toggleSection("Mein-MMO", isOn: o.combinePages, label: "Combine Multi-page Articles") {
                    var n = o; n.combinePages = $0; options = .meinMmo(n)
                }
            }

            aiSection
        }
    }

    // MARK: - Shared AI block

    private var aiSection: some View {
        Section("AI Post-Processing") {
            let ai = aiBinding
            Toggle("Summarize", isOn: ai.summarize)
            Toggle("Improve Writing", isOn: ai.improveWriting)
            Toggle("Translate", isOn: ai.translate)
            if ai.translate.wrappedValue {
                TextField("Translate to", text: ai.translateLanguage)
            }
        }
    }

    /// A binding to the active case's `AIOptions`, writing the whole case back on change.
    private var aiBinding: Binding<AIOptions> {
        Binding(
            get: { options.ai },
            set: { newAI in
                switch options {
                case .fullWebsite(var o): o.ai = newAI; options = .fullWebsite(o)
                case .feedContent(var o): o.ai = newAI; options = .feedContent(o)
                case .reddit(var o): o.ai = newAI; options = .reddit(o)
                case .youtube(var o): o.ai = newAI; options = .youtube(o)
                case .podcast(var o): o.ai = newAI; options = .podcast(o)
                case .heise(var o): o.ai = newAI; options = .heise(o)
                case .merkur(var o): o.ai = newAI; options = .merkur(o)
                case .tagesschau(var o): o.ai = newAI; options = .tagesschau(o)
                case .explosm(var o): o.ai = newAI; options = .explosm(o)
                case .darkLegacy(var o): o.ai = newAI; options = .darkLegacy(o)
                case .caschysBlog(var o): o.ai = newAI; options = .caschysBlog(o)
                case .mactechnews(var o): o.ai = newAI; options = .mactechnews(o)
                case .oglaf(var o): o.ai = newAI; options = .oglaf(o)
                case .meinMmo(var o): o.ai = newAI; options = .meinMmo(o)
                }
            }
        )
    }

    // MARK: - Per-type sections

    private func toggleSection(_ title: String, isOn: Bool, label: LocalizedStringKey, set: @escaping (Bool) -> Void) -> some View {
        Section("Options") {
            Toggle(label, isOn: Binding(get: { isOn }, set: set))
        }
    }

    private func websiteSection(_ o: WebsiteOptions) -> some View {
        Section("Options") {
            Toggle("Fetch Full Content", isOn: Binding(get: { o.useFullContent }, set: { var n = o; n.useFullContent = $0; options = .fullWebsite(n) }))
            TextField("Custom Content Selector", text: Binding(get: { o.customContentSelector }, set: { var n = o; n.customContentSelector = $0; options = .fullWebsite(n) }))
                .autocorrectionDisabled()
            TextField("Selectors to Remove", text: Binding(get: { o.customSelectorsToRemove }, set: { var n = o; n.customSelectorsToRemove = $0; options = .fullWebsite(n) }))
                .autocorrectionDisabled()
        }
    }

    private func redditSection(_ o: RedditOptions) -> some View {
        Section("Options") {
            Picker("Sort Order", selection: Binding(get: { o.subredditSort }, set: { var n = o; n.subredditSort = $0; options = .reddit(n) })) {
                Text("Hot").tag("hot")
                Text("New").tag("new")
                Text("Top").tag("top")
                Text("Rising").tag("rising")
            }
            Stepper("Minimum Comments: \(o.minComments)", value: Binding(get: { o.minComments }, set: { var n = o; n.minComments = $0; options = .reddit(n) }), in: 0...500)
            Stepper("Comment Limit: \(o.commentLimit)", value: Binding(get: { o.commentLimit }, set: { var n = o; n.commentLimit = $0; options = .reddit(n) }), in: 0...50)
            Stepper("Minimum Post Age: \(o.minAgeHours)h", value: Binding(get: { o.minAgeHours }, set: { var n = o; n.minAgeHours = $0; options = .reddit(n) }), in: 0...168)
            Toggle("Include Header Image", isOn: Binding(get: { o.includeHeaderImage }, set: { var n = o; n.includeHeaderImage = $0; options = .reddit(n) }))
        }
    }

    private func youtubeSection(_ o: YouTubeOptions) -> some View {
        Section("Options") {
            Stepper("Comment Limit: \(o.commentLimit)", value: Binding(get: { o.commentLimit }, set: { var n = o; n.commentLimit = $0; options = .youtube(n) }), in: 0...50)
        }
    }

    private func podcastSection(_ o: PodcastOptions) -> some View {
        Section("Options") {
            Toggle("Include Audio Player", isOn: Binding(get: { o.includePlayer }, set: { var n = o; n.includePlayer = $0; options = .podcast(n) }))
            Toggle("Include Download Link", isOn: Binding(get: { o.includeDownloadLink }, set: { var n = o; n.includeDownloadLink = $0; options = .podcast(n) }))
            Stepper("Artwork Max Width: \(o.artworkSize)", value: Binding(get: { o.artworkSize }, set: { var n = o; n.artworkSize = $0; options = .podcast(n) }), in: 100...1200, step: 50)
        }
    }

    private func heiseSection(_ o: HeiseOptions) -> some View {
        Section("Options") {
            Toggle("Include Forum Comments", isOn: Binding(get: { o.includeComments }, set: { var n = o; n.includeComments = $0; options = .heise(n) }))
            Stepper("Max Comments: \(o.maxComments)", value: Binding(get: { o.maxComments }, set: { var n = o; n.maxComments = $0; options = .heise(n) }), in: 0...50)
        }
    }

    private func mactechnewsSection(_ o: MactechnewsOptions) -> some View {
        Section("Options") {
            Toggle("Combine Multi-page Articles", isOn: Binding(get: { o.combinePages }, set: { var n = o; n.combinePages = $0; options = .mactechnews(n) }))
            Toggle("Include Comments", isOn: Binding(get: { o.includeComments }, set: { var n = o; n.includeComments = $0; options = .mactechnews(n) }))
            Stepper("Max Comments: \(o.maxComments)", value: Binding(get: { o.maxComments }, set: { var n = o; n.maxComments = $0; options = .mactechnews(n) }), in: 0...50)
        }
    }

    private func tagesschauSection(_ o: TagesschauOptions) -> some View {
        Section("Options") {
            Toggle("Skip Livestreams", isOn: Binding(get: { o.skipLivestreams }, set: { var n = o; n.skipLivestreams = $0; options = .tagesschau(n) }))
            Toggle("Skip Videos", isOn: Binding(get: { o.skipVideos }, set: { var n = o; n.skipVideos = $0; options = .tagesschau(n) }))
        }
    }

    private func oglafSection(_ o: OglafOptions) -> some View {
        Section("Options") {
            Toggle("Show Alt Text", isOn: Binding(get: { o.showAltText }, set: { var n = o; n.showAltText = $0; options = .oglaf(n) }))
            Toggle("Convert to Base64", isOn: Binding(get: { o.convertToBase64 }, set: { var n = o; n.convertToBase64 = $0; options = .oglaf(n) }))
        }
    }
}
```

- [ ] **Step 2: Create `FeedEditorView`**

Create `Yana/Views/Config/FeedEditorView.swift`:

```swift
import SwiftData
import SwiftUI

/// Create or edit a `Feed`. New feeds are inserted on save; existing feeds are updated.
struct FeedEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var allTags: [Tag]

    /// nil = create a new feed.
    let feed: Feed?
    @State private var model: FeedEditorModel

    init(feed: Feed?) {
        self.feed = feed
        _model = State(initialValue: FeedEditorModel(feed: feed))
    }

    var body: some View {
        Form {
            Section("Feed") {
                TextField("Name", text: $model.name)
                Picker("Type", selection: Binding(get: { model.type }, set: { model.changeType($0) })) {
                    ForEach(AggregatorType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                if model.type.identifierKind != .none {
                    TextField(identifierLabel, text: $model.identifier)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Stepper("Daily Limit: \(model.dailyLimit)", value: $model.dailyLimit, in: 1...200)
                Toggle("Enabled", isOn: $model.enabled)
            }

            Section("Tags") {
                if allTags.isEmpty {
                    Text("No tags yet. Create tags in the Tags screen.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(allTags) { tag in
                        Button {
                            toggleTag(tag.name)
                        } label: {
                            HStack {
                                Text(tag.name)
                                Spacer()
                                if model.selectedTagNames.contains(tag.name) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            AggregatorOptionsForm(options: $model.options)
        }
        .navigationTitle(model.isEditingExisting ? "Edit Feed" : "New Feed")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!model.isValid)
            }
        }
    }

    private var identifierLabel: String {
        switch model.type.identifierKind {
        case .url: String(localized: "Feed URL")
        case .subreddit: String(localized: "Subreddit (e.g. swift)")
        case .youtubeChannel: String(localized: "YouTube Channel ID or handle")
        case .none: ""
        }
    }

    private func toggleTag(_ name: String) {
        if model.selectedTagNames.contains(name) {
            model.selectedTagNames.remove(name)
        } else {
            model.selectedTagNames.insert(name)
        }
    }

    private func save() {
        let target = feed ?? Feed(name: "", aggregatorType: .feedContent, identifier: "")
        model.apply(to: target, availableTags: allTags)
        if feed == nil { modelContext.insert(target) }
        try? modelContext.save()
        dismiss()
    }
}
```

- [ ] **Step 3: Create `ConfigHubView` and repoint the reader sheet**

Create `Yana/Views/Config/ConfigHubView.swift`:

```swift
import SwiftUI

/// Root of the configuration sheet. Links to Feeds, Tags, and Settings.
struct ConfigHubView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    FeedsView()
                } label: {
                    Label("Feeds", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    TagsView()
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                NavigationLink {
                    SettingsScreenView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
```

Delete `Yana/Views/SettingsView.swift`. In `Yana/Views/ArticleReaderView.swift`, change the settings sheet to present the hub:

```swift
            .sheet(isPresented: $appState.showSettings) {
                ConfigHubView()
            }
```

> `FeedsView`, `TagsView`, and `SettingsScreenView` are created in Tasks 9 and 10. Build verification for this task happens at the **end of Task 10**, once all three referenced views exist.

- [ ] **Step 4: Run `xcodegen generate`**

Run: `xcodegen generate`
Expected: project regenerated (new files added, `SettingsView.swift` removed).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: config hub shell, dynamic options form, feed editor"
```

---

## Task 9: `FeedsView` + `TagsView`

**Files:**
- Create: `Yana/Views/Config/FeedsView.swift`
- Create: `Yana/Views/Config/TagsView.swift`
- Create: `Yana/Views/Config/TagEditorView.swift`

- [ ] **Step 1: Create `FeedsView`**

Create `Yana/Views/Config/FeedsView.swift`:

```swift
import SwiftData
import SwiftUI

/// Flat list of feeds with tag chips, last-fetched time, error badge, enable toggle,
/// per-feed update, and article count. Add / delete; "Update all".
struct FeedsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @State private var isUpdating = false

    var body: some View {
        List {
            ForEach(feeds) { feed in
                NavigationLink {
                    FeedEditorView(feed: feed)
                } label: {
                    row(feed)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(feed)
                        try? modelContext.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await updateOne(feed) }
                    } label: {
                        Label("Update", systemImage: "arrow.clockwise")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Feeds")
        .overlay {
            if feeds.isEmpty {
                ContentUnavailableView("No Feeds", systemImage: "list.bullet.rectangle",
                                       description: Text("Tap + to add your first feed."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    FeedEditorView(feed: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Update All") { Task { await updateAll() } }
                    .disabled(isUpdating || feeds.isEmpty)
            }
        }
    }

    private func row(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.name).font(.headline)
                if !feed.enabled {
                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                }
                if feed.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            HStack(spacing: 6) {
                Text(feed.type.displayName)
                Text("· \(feed.articles.count) articles")
                if let fetched = feed.lastFetchedAt {
                    Text("· \(fetched, style: .relative) ago")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !feed.tags.isEmpty {
                Text(feed.tags.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        await AggregationService(context: modelContext).updateAll()
    }

    private func updateOne(_ feed: Feed) async {
        await AggregationService(context: modelContext).update(feed: feed)
    }
}
```

- [ ] **Step 2: Create `TagEditorView`**

Create `Yana/Views/Config/TagEditorView.swift`:

```swift
import SwiftData
import SwiftUI

/// Create or rename/recolor a tag. The built-in Starred tag can be recolored but not renamed.
struct TagEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let tag: Tag?
    @State private var name: String
    @State private var color: Color

    init(tag: Tag?) {
        self.tag = tag
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: Color(hex: tag?.colorHex) ?? .accentColor)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .disabled(tag?.isBuiltIn == true)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            }
            .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag {
            if !tag.isBuiltIn { tag.name = trimmed }
            tag.colorHex = color.toHex()
        } else {
            let maxOrder = (try? modelContext.fetch(FetchDescriptor<Tag>()))?.map(\.sortOrder).max() ?? 0
            modelContext.insert(Tag(name: trimmed, colorHex: color.toHex(), sortOrder: maxOrder + 1))
        }
        try? modelContext.save()
        dismiss()
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
```

- [ ] **Step 3: Create `TagsView`**

Create `Yana/Views/Config/TagsView.swift`:

```swift
import SwiftData
import SwiftUI

/// Tag CRUD: create / rename / recolor / delete / reorder. The built-in Starred tag is
/// locked (recolor only; no delete or rename).
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var editingTag: Tag?
    @State private var isCreating = false

    var body: some View {
        List {
            ForEach(tags) { tag in
                Button {
                    editingTag = tag
                } label: {
                    HStack {
                        Circle().fill(Color(hex: tag.colorHex) ?? .accentColor).frame(width: 14, height: 14)
                        Text(tag.name)
                        if tag.isBuiltIn {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .tint(.primary)
            }
            .onDelete(perform: delete)
            .onMove(perform: move)
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .sheet(item: $editingTag) { tag in TagEditorView(tag: tag) }
        .sheet(isPresented: $isCreating) { TagEditorView(tag: nil) }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            let tag = tags[index]
            guard !tag.isBuiltIn else { continue } // Starred is locked
            modelContext.delete(tag)
        }
        try? modelContext.save()
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        var reordered = tags
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, tag) in reordered.enumerated() { tag.sortOrder = index }
        try? modelContext.save()
    }
}
```

- [ ] **Step 4: Run `xcodegen generate`**

Run: `xcodegen generate`
Expected: project regenerated.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: FeedsView, TagsView, TagEditorView"
```

---

## Task 10: `SettingsScreenView` (full parity)

**Files:**
- Create: `Yana/Views/Config/SettingsScreenView.swift`

- [ ] **Step 1: Create `SettingsScreenView`**

Create `Yana/Views/Config/SettingsScreenView.swift`:

```swift
import SwiftUI

/// Full-parity settings: sources (Reddit/YouTube), AI providers + knobs, library prefs.
/// Secrets are read from / written to the Keychain via local @State; non-secret prefs go to
/// `AppSettings` (UserDefaults).
struct SettingsScreenView: View {
    @State private var settings = AppSettings()

    // Keychain-backed secrets (loaded onAppear, written on change).
    @State private var redditClientID = ""
    @State private var redditClientSecret = ""
    @State private var youtubeKey = ""
    @State private var openaiKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""

    var body: some View {
        Form {
            redditSection
            youtubeSection
            aiProviderSection
            aiKnobsSection
            librarySection
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadSecrets)
    }

    // MARK: Sources

    private var redditSection: some View {
        Section("Reddit") {
            Toggle("Enabled", isOn: $settings.redditEnabled)
            SecureField("Client ID", text: $redditClientID)
                .onChange(of: redditClientID) { _, v in KeychainService.saveAPIKey(v, for: .redditClientID) }
            SecureField("Client Secret", text: $redditClientSecret)
                .onChange(of: redditClientSecret) { _, v in KeychainService.saveAPIKey(v, for: .redditClientSecret) }
            TextField("User Agent", text: $settings.redditUserAgent)
                .autocorrectionDisabled()
        }
    }

    private var youtubeSection: some View {
        Section("YouTube") {
            Toggle("Enabled", isOn: $settings.youtubeEnabled)
            SecureField("API Key", text: $youtubeKey)
                .onChange(of: youtubeKey) { _, v in KeychainService.saveAPIKey(v, for: .youtubeAPIKey) }
        }
    }

    // MARK: AI providers

    private var aiProviderSection: some View {
        Section("AI Provider") {
            Picker("Active Provider", selection: $settings.activeAIProvider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            }

            DisclosureGroup("OpenAI") {
                Toggle("Enabled", isOn: $settings.openaiEnabled)
                SecureField("API Key", text: $openaiKey)
                    .onChange(of: openaiKey) { _, v in KeychainService.saveAPIKey(v, for: .openaiAPIKey) }
                TextField("API URL", text: $settings.openaiAPIURL).autocorrectionDisabled()
                Picker("Model", selection: $settings.openaiModel) {
                    ForEach(AIProvider.openai.models, id: \.self) { Text($0).tag($0) }
                }
            }
            DisclosureGroup("Anthropic") {
                Toggle("Enabled", isOn: $settings.anthropicEnabled)
                SecureField("API Key", text: $anthropicKey)
                    .onChange(of: anthropicKey) { _, v in KeychainService.saveAPIKey(v, for: .anthropicAPIKey) }
                Picker("Model", selection: $settings.anthropicModel) {
                    ForEach(AIProvider.anthropic.models, id: \.self) { Text($0).tag($0) }
                }
            }
            DisclosureGroup("Gemini") {
                Toggle("Enabled", isOn: $settings.geminiEnabled)
                SecureField("API Key", text: $geminiKey)
                    .onChange(of: geminiKey) { _, v in KeychainService.saveAPIKey(v, for: .geminiAPIKey) }
                Picker("Model", selection: $settings.geminiModel) {
                    ForEach(AIProvider.gemini.models, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private var aiKnobsSection: some View {
        Section("AI Tuning") {
            HStack {
                Text("Temperature")
                Slider(value: $settings.aiTemperature, in: 0...1, step: 0.05)
                Text(settings.aiTemperature, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Stepper("Max Tokens: \(settings.aiMaxTokens)", value: $settings.aiMaxTokens, in: 256...8000, step: 256)
            Stepper("Max Prompt Length: \(settings.aiMaxPromptLength)", value: $settings.aiMaxPromptLength, in: 100...4000, step: 100)
            Stepper("Daily Limit: \(settings.aiDefaultDailyLimit)", value: $settings.aiDefaultDailyLimit, in: 0...5000, step: 50)
            Stepper("Monthly Limit: \(settings.aiDefaultMonthlyLimit)", value: $settings.aiDefaultMonthlyLimit, in: 0...50000, step: 100)
            Stepper("Request Timeout: \(settings.aiRequestTimeout)s", value: $settings.aiRequestTimeout, in: 10...600, step: 10)
            Stepper("Max Retries: \(settings.aiMaxRetries)", value: $settings.aiMaxRetries, in: 0...10)
            Stepper("Retry Delay: \(settings.aiRetryDelay)s", value: $settings.aiRetryDelay, in: 0...60)
            Stepper("Request Delay: \(settings.aiRequestDelay)s", value: $settings.aiRequestDelay, in: 0...60)
        }
    }

    private var librarySection: some View {
        Section("Library") {
            Stepper("Keep Articles: \(settings.retentionDays) days", value: $settings.retentionDays, in: 1...365)
            Stepper("Background Refresh: \(Int(settings.backgroundInterval / 60)) min", value: $settings.backgroundInterval, in: 300...21600, step: 300)
        }
    }

    private func loadSecrets() {
        redditClientID = KeychainService.loadAPIKey(for: .redditClientID) ?? ""
        redditClientSecret = KeychainService.loadAPIKey(for: .redditClientSecret) ?? ""
        youtubeKey = KeychainService.loadAPIKey(for: .youtubeAPIKey) ?? ""
        openaiKey = KeychainService.loadAPIKey(for: .openaiAPIKey) ?? ""
        anthropicKey = KeychainService.loadAPIKey(for: .anthropicAPIKey) ?? ""
        geminiKey = KeychainService.loadAPIKey(for: .geminiAPIKey) ?? ""
    }
}
```

- [ ] **Step 2: Run `xcodegen generate` and build**

Run: `xcodegen generate`
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (ConfigHubView now resolves FeedsView, TagsView, SettingsScreenView).

- [ ] **Step 3: Run the full test suite (regression)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: full-parity settings screen"
```

---

## Task 11: Timeline reader — position memory, star toggle, pull-down refresh, tag filter

**Files:**
- Create: `Yana/Views/TagFilterView.swift`
- Modify: `Yana/Views/ArticleReaderView.swift`
- Modify: `Yana/Models/AppState.swift`

- [ ] **Step 1: Trim `AppState`**

Replace `Yana/Models/AppState.swift`:

```swift
import Foundation

@MainActor
@Observable
final class AppState {
    /// Index into the (filtered) timeline.
    var currentIndex: Int = 0
    var isUpdating = false
    var errorMessage: String?
    var showSettings = false
    var showFilter = false
}
```

- [ ] **Step 2: Create `TagFilterView`**

Create `Yana/Views/TagFilterView.swift`:

```swift
import SwiftData
import SwiftUI

/// Filter sheet: every tag plus an "Untagged" entry, each a toggle. All active by default.
/// Writes the disabled set / untagged flag to `AppSettings`.
struct TagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var settings = AppSettings()
    /// Local mirror so toggles animate; synced to settings on change.
    @State private var disabled: Set<String> = []
    @State private var includeUntagged = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    toggleRow(tag.name, isActive: !disabled.contains(tag.name)) { active in
                        if active { disabled.remove(tag.name) } else { disabled.insert(tag.name) }
                        settings.disabledTagNames = disabled
                    }
                }
                toggleRow(String(localized: "Untagged"), isActive: includeUntagged) { active in
                    includeUntagged = active
                    settings.includeUntagged = active
                }
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                disabled = settings.disabledTagNames
                includeUntagged = settings.includeUntagged
            }
        }
    }

    private func toggleRow(_ name: String, isActive: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isActive }, set: set))
    }
}
```

- [ ] **Step 3: Rewrite `ArticleReaderView` as the timeline**

Replace the contents of `Yana/Views/ArticleReaderView.swift` (keep the `ShareSheet` struct at the bottom):

```swift
import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var dragOffset: CGFloat = 0
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    /// The timeline after applying the persisted tag filter.
    private var articles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }

    private var currentArticle: Article? {
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return nil }
        return articles[appState.currentIndex]
    }

    private var starredTag: Tag? { builtInTags.first }

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
                        Label("No Articles", systemImage: "tray")
                    } description: {
                        Text("Add feeds in Configuration, then pull down to refresh.")
                    }
                }
            }
            .refreshable { await refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { appState.showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let article = currentArticle, let starredTag {
                        Button {
                            article.setStarred(!article.isStarred, using: starredTag)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: article.isStarred ? "star.fill" : "star")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { appState.showSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
            .sheet(isPresented: $appState.showFilter) { TagFilterView() }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
            .onAppear { restoreAnchor() }
            .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
        }
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
    }

    private func saveAnchor() {
        settings.timelineAnchorIdentifier = currentArticle?.identifier
    }

    // MARK: - Refresh

    private func refresh() async {
        let service = AggregationService(context: modelContext)
        if let article = currentArticle { await service.update(article: article) }
        await service.updateAll()
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
        .safeAreaInset(edge: .bottom) { bottomBar(article) }
    }

    private func bottomBar(_ article: Article) -> some View {
        HStack {
            Spacer()
            if let url = URL(string: article.url) {
                Button { UIApplication.shared.open(url) } label: {
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

    // MARK: - Swipe Gesture (bidirectional, no read state)

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in dragOffset = value.translation.width }
            .onEnded { value in
                let threshold: CGFloat = 100
                if value.translation.width < -threshold, appState.currentIndex < articles.count - 1 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = -UIScreen.main.bounds.width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex += 1
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold, appState.currentIndex > 0 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = UIScreen.main.bounds.width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex -= 1
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.interactiveSpring) { dragOffset = 0 }
                }
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
```

- [ ] **Step 4: Run `xcodegen generate` and build**

Run: `xcodegen generate`
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: endless timeline reader with tag filter, star, position memory, pull-to-refresh"
```

---

## Task 12: Manual smoke test + localization sweep

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings` (via Xcode build extraction)

- [ ] **Step 1: Build extracts strings**

`SWIFT_EMIT_LOC_STRINGS: YES` is already set, so a build extracts new `String(localized:)` keys. Run a build, then open `Yana/Resources/Localizable.xcstrings` in Xcode and confirm the new UI strings (e.g. "Configuration", "Feeds", "Tags", "Filter", "Untagged", "AI Tuning") are present. Provide translations as needed (English is the source and needs no translation).

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Manual smoke test (simulator)**

Use the `run` skill (or Xcode) to launch the app and verify, since views have no unit tests:
- Open Configuration → Tags: the locked **Starred** tag is present; create "Tech" and "Fun"; reorder; recolor; delete a non-builtin (Starred cannot be deleted).
- Configuration → Feeds → +: create a feed of several types; confirm the **identifier label adapts** (URL vs Subreddit vs Channel) and **disappears** for Oglaf/Explosm/Dark Legacy/Tagesschau; confirm the **Options section changes per type** (e.g. Reddit shows sort + min-age; Oglaf shows Convert to Base64); assign a tag; Save.
- Configuration → Settings: enter keys (verify they persist across reopening — they load from Keychain), toggle providers, change models, adjust knobs, change retention.
- Reader: with no articles, the "No Articles" state shows; the filter button opens the sheet listing tags + Untagged (all on); the gear opens Configuration. Pull-to-refresh runs without crashing (stub touches `lastFetchedAt`).

- [ ] **Step 3: Commit any string-catalog changes**

```bash
git add -A
git commit -m "chore: extract Phase 2 localizable strings"
```

---

## Self-Review Notes (already reconciled)

- **Spec coverage:** Tag model + seeding (T1), retag Feed/Article + drop read/group (T2), per-scraper options incl. `minAgeHours`/`convertToBase64` and dropped `fetchFullContent` (T3), full `AppSettings` parity + model lists (T4), tag filter + anchor (T5), service stub (T6), feed-editor bridge (T7), config hub + dynamic options + feed editor (T8), feeds/tags CRUD (T9), settings screen (T10), timeline reader with filter/star/anchor/pull-refresh (T11), localization (T12). All spec UI surfaces and data-model changes map to a task.
- **Type consistency:** `Tag.ensureBuiltIns`, `Tag.starredName`, `Article.isStarred`/`setStarred(_:using:)`, `TagFilter.apply(to:disabledTagNames:includeUntagged:)`, `TimelineAnchor.index(for:in:)`, `FeedEditorModel.changeType`/`apply(to:availableTags:)`, `AggregationService(context:)`/`updateAll()`/`update(feed:)`/`update(article:)`, and the `AppSettings` property names are used identically across tasks and tests.
- **Ordering constraint:** Tasks 1–2 compile together (cross-references between `Tag` and `Feed`/`Article`); Task 8's `ConfigHubView` only fully builds after Task 10. These dependencies are called out inline.
- **Model-list caveat:** the per-provider model id lists in Task 4 are current at planning time and intentionally maintained in code — verify against each provider's current API model ids when implementing.
