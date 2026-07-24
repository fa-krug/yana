# iCloud Article Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync full article bodies + image blobs across a user's devices via CloudKit so every device shows an identical timeline, with a passive-device mode that consumes without aggregating.

**Architecture:** A new `ArticleSyncService` (mirroring the existing `ConfigSyncService`) mirrors local SwiftData `Article`s to/from a dedicated CloudKit zone driven by `CKSyncEngine`. Articles are one `SyncedArticle` record each (keyed by a canonical UID as `recordName`); images are content-addressed `SyncedImage` records (keyed by hash). All logic lives behind an `ArticleZoneStore` protocol so it's unit-testable with a fake; the production `CKSyncEngine` adapter is the only untested-by-unit piece. Config sync stays as-is except for retiring `starredData` and swapping the timeline-position representation.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftData, CloudKit (`CKSyncEngine`, iOS 17+ API), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform floor: **iOS 26.0+** (iPhone + iPad + Mac Catalyst). `CKSyncEngine` is available.
- CloudKit container: **`iCloud.de.fa-krug.Yana`** (private database). Schema auto-creates in Development on first write; **must be deployed to Production before release**.
- Everything gated on **`AppSettings.iCloudSyncEnabled`** (opt-in, off by default). When off, every entry point returns immediately and no CloudKit object is constructed.
- The SwiftData store stays **local-only** (`ModelConfiguration(cloudKitDatabase: .none)`). We never enable SwiftData's own CloudKit mirroring.
- Strict concurrency: types crossing actor boundaries must be `Sendable`; never carry a non-`Sendable` `Article`/`Feed`/`ModelContext` across a boundary — carry `Sendable` value structs or `PersistentIdentifier`.
- **Every new user-facing string** must be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state" : "translated"` (Apple-style German: infinitive for actions, no "Du"/"Sie").
- Canonical article UID = `"\(feedIdentifier)|\(aggregatorType)|\(articleIdentifier)"`, with a `SHA256("\(date.timeIntervalSince1970)|\(title)")` fallback when `articleIdentifier` is empty.
- Conflict rules: `createdAt` **first-writer-wins**; all other fields **last-writer-wins**.
- Build/test command (whole suite):
  `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
  Single suite: append `-only-testing:YanaTests/<SuiteName>`.
- Regenerate the project after adding files: `xcodegen generate` (files are picked up by directory globs in `project.yml`, so no manual project edits — but regenerate before building).

---

## File structure

**New files:**
- `Yana/Services/ArticleSync/SyncedArticleRecord.swift` — the `Sendable` value structs (`SyncedArticleRecord`, `SyncedImageRecord`, `ArticleZoneChanges`) + `ArticleUID` + `ArticleImageRefs`.
- `Yana/Services/ArticleSync/ArticleRecordMapping.swift` — `Article` ⇄ `SyncedArticleRecord` conversion helpers.
- `Yana/Services/ArticleSync/ArticleZoneStore.swift` — the `ArticleZoneStore` protocol + `ArticleZoneStoreError`.
- `Yana/Services/ArticleSync/ArticleSyncService.swift` — the orchestration service (pull/reconcile/push/deletion, gating, canonical-createdAt index).
- `Yana/Services/ArticleSync/CloudKitArticleZoneStore.swift` — production `CKSyncEngine` adapter.
- `YanaTests/ArticleSync/FakeArticleZoneStore.swift` — test double + shared harness helpers.
- `YanaTests/ArticleSync/ArticleUIDTests.swift`
- `YanaTests/ArticleSync/ArticleRecordMappingTests.swift`
- `YanaTests/ArticleSync/ArticleSyncPullTests.swift`
- `YanaTests/ArticleSync/ArticleSyncPushTests.swift`
- `YanaTests/ArticleSync/ArticleSyncImageTests.swift`
- `YanaTests/ArticleSync/ArticleSyncRetentionTests.swift`
- `YanaTests/ArticleSync/PassiveDeviceTests.swift`

**Modified files:**
- `Yana/Utilities/ImageStore.swift` — add byte/ext/existence accessors (Task 4).
- `Yana/Services/ArticleUpsert.swift` — canonical-createdAt adoption hook (Task 5).
- `Yana/Services/AggregationService.swift` — pull-before-run, push-after-run, deletion propagation, passive/retention gating (Tasks 5–7).
- `Yana/Services/RetentionCleanup.swift` — return deleted UIDs (Task 6).
- `Yana/Services/BackgroundRefreshManager.swift` — skip when passive (Task 7).
- `Yana/Models/AppSettings.swift` — `isPassiveDevice`; swap `timelinePosition` → `timelineAnchorUID`; drop `syncTimelinePositionEnabled`; retire `starredData` wiring (Tasks 7–8).
- `Yana/Services/ConfigSyncService.swift` — drop `starredData` from `ConfigDocument` (Task 8).
- `Yana/Reader/ReaderHostView.swift` + `Yana/Reader/Mac/TimelineModel.swift` — position anchor via UID (Task 8).
- `Yana/YanaApp.swift` — start/pull article sync at launch; route remote push (Task 9).
- `Yana/Views/Config/SettingsScreenView.swift` — passive toggle replaces position toggle; footer copy (Task 9).
- `Yana/Resources/Localizable.xcstrings` — new strings (Task 9).
- `CLAUDE.md` — document article sync (Task 10).

---

## Task 1: Record types, UID, and image-ref extraction

**Files:**
- Create: `Yana/Services/ArticleSync/SyncedArticleRecord.swift`
- Test: `YanaTests/ArticleSync/ArticleUIDTests.swift`

**Interfaces:**
- Produces:
  - `struct SyncedArticleRecord: Sendable, Equatable` with fields: `uid, feedIdentifier, aggregatorType, articleIdentifier: String`, `title, url, author, summary, plainText, leadImageRef: String`, `iconURL: String?`, `date, createdAt: Date`, `blockData: Data`, `isStarred: Bool`, `tagNames: [String]`, `imageHashes: [String]`.
  - `struct SyncedImageRecord: Sendable, Equatable { let hash: String; let ext: String; let data: Data }`
  - `struct ArticleZoneChanges: Sendable, Equatable { var articles: [SyncedArticleRecord]; var deletedUIDs: [String] }`
  - `enum ArticleUID { static func make(feedIdentifier:aggregatorType:articleIdentifier:date:title:) -> String }`
  - `enum ArticleImageRefs { static func hashes(in: [Block]) -> [String]; static func hash(from ref: String) -> String? }`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSync/ArticleUIDTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("ArticleUID")
struct ArticleUIDTests {
    @Test("UID uses the triple when articleIdentifier is present")
    func triple() {
        let uid = ArticleUID.make(
            feedIdentifier: "https://feed.example/rss",
            aggregatorType: "feedContent",
            articleIdentifier: "https://feed.example/post/1",
            date: Date(timeIntervalSince1970: 1000),
            title: "Hello"
        )
        #expect(uid == "https://feed.example/rss|feedContent|https://feed.example/post/1")
    }

    @Test("UID falls back to a date+title hash when articleIdentifier is empty")
    func fallback() {
        let uid = ArticleUID.make(
            feedIdentifier: "f", aggregatorType: "feedContent",
            articleIdentifier: "", date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid.hasPrefix("f|feedContent|"))
        // Deterministic: same inputs → same UID.
        let again = ArticleUID.make(
            feedIdentifier: "f", aggregatorType: "feedContent",
            articleIdentifier: "", date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid == again)
        // The fallback segment is not empty.
        #expect(uid != "f|feedContent|")
    }

    @Test("Image hashes are collected from nested blocks and deduped")
    func imageHashes() {
        let blocks: [Block] = [
            .image(ref: "yana-img://aaa", caption: []),
            .blockquote([.image(ref: "yana-img://bbb", caption: [])]),
            .list(ordered: false, items: [[.image(ref: "yana-img://aaa", caption: [])]]),
            .embed(Embed(provider: .video, thumbnailRef: "yana-img://ccc", externalURL: "x", title: nil)),
            .paragraph([InlineRun(text: "no image")])
        ]
        let hashes = Set(ArticleImageRefs.hashes(in: blocks))
        #expect(hashes == ["aaa", "bbb", "ccc"])
    }

    @Test("hash(from:) only unwraps the yana-img scheme")
    func hashFrom() {
        #expect(ArticleImageRefs.hash(from: "yana-img://deadbeef") == "deadbeef")
        #expect(ArticleImageRefs.hash(from: "https://remote/x.jpg") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleUID`
Expected: FAIL — `cannot find 'ArticleUID' in scope` / `ArticleImageRefs`.

- [ ] **Step 3: Write the implementation**

Create `Yana/Services/ArticleSync/SyncedArticleRecord.swift`:

```swift
import Foundation
import CryptoKit

/// A single article as it travels through the CloudKit `Articles` zone. `Sendable` value type so it
/// crosses actor boundaries freely. `uid` is the record name; the triple fields let a receiving
/// device link the article to its `Feed`. Bodies are the JSON `[Block]` in `blockData`.
struct SyncedArticleRecord: Sendable, Equatable {
    var uid: String
    var feedIdentifier: String
    var aggregatorType: String
    var articleIdentifier: String
    var title: String
    var url: String
    var author: String
    var summary: String
    var plainText: String
    var leadImageRef: String
    var iconURL: String?
    var date: Date
    var createdAt: Date
    var blockData: Data
    var isStarred: Bool
    var tagNames: [String]
    var imageHashes: [String]
}

/// A content-addressed image blob. `hash` is the record name; `ext` restores the file extension so
/// `ImageStore.fileURL(forHash:)` resolves the right file after a pull.
struct SyncedImageRecord: Sendable, Equatable {
    let hash: String
    let ext: String
    let data: Data
}

/// The delta a pull produces: upserted article records and tombstoned UIDs.
struct ArticleZoneChanges: Sendable, Equatable {
    var articles: [SyncedArticleRecord]
    var deletedUIDs: [String]

    static let empty = ArticleZoneChanges(articles: [], deletedUIDs: [])
}

/// Derives the canonical, cross-device article identity. Uses the stable `(feed, type, identifier)`
/// triple (the same key `StarredMark` uses); when a feed yields no `articleIdentifier`, a
/// deterministic `date+title` hash fills the third segment so the UID is still unique and stable.
enum ArticleUID {
    static func make(
        feedIdentifier: String,
        aggregatorType: String,
        articleIdentifier: String,
        date: Date,
        title: String
    ) -> String {
        let third: String
        if articleIdentifier.isEmpty {
            let seed = "\(date.timeIntervalSince1970)|\(title)"
            let digest = SHA256.hash(data: Data(seed.utf8))
            third = digest.map { String(format: "%02x", $0) }.joined()
        } else {
            third = articleIdentifier
        }
        return "\(feedIdentifier)|\(aggregatorType)|\(third)"
    }
}

/// Collects the `yana-img://<hash>` image hashes referenced anywhere in a block tree (image blocks
/// and embed posters, recursing into blockquotes and list items), deduped.
enum ArticleImageRefs {
    static func hash(from ref: String) -> String? {
        let prefix = "\(ReaderWeb.imageScheme)://"   // "yana-img://"
        guard ref.hasPrefix(prefix) else { return nil }
        let hash = String(ref.dropFirst(prefix.count))
        return hash.isEmpty ? nil : hash
    }

    static func hashes(in blocks: [Block]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ ref: String) {
            guard let h = hash(from: ref), seen.insert(h).inserted else { return }
            ordered.append(h)
        }
        func visit(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case .image(let ref, _): add(ref)
                case .embed(let embed): if let ref = embed.thumbnailRef { add(ref) }
                case .blockquote(let inner): visit(inner)
                case .list(_, let items): items.forEach(visit)
                case .paragraph, .heading, .codeBlock, .divider: break
                }
            }
        }
        visit(blocks)
        return ordered
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleUID`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleSync/SyncedArticleRecord.swift YanaTests/ArticleSync/ArticleUIDTests.swift
git commit -m "Add article-sync record types, canonical UID, and image-ref extraction"
```

---

## Task 2: Article ⇄ record mapping

**Files:**
- Create: `Yana/Services/ArticleSync/ArticleRecordMapping.swift`
- Test: `YanaTests/ArticleSync/ArticleRecordMappingTests.swift`

**Interfaces:**
- Consumes: `SyncedArticleRecord`, `ArticleUID`, `ArticleImageRefs` (Task 1).
- Produces:
  - `extension SyncedArticleRecord { init?(article: Article) }` — nil when the article has no `feed` (can't form the triple).
  - `enum ArticleRecordApply { @MainActor static func apply(_ record: SyncedArticleRecord, into context: ModelContext, starredTag: Tag?, feedsByKey: [String: Feed]) -> Article }` — upsert one record into local SwiftData, first-writer-wins `createdAt`, last-writer-wins everything else, links feed by `(feedIdentifier|aggregatorType)` or leaves `feed` nil.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSync/ArticleRecordMappingTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleRecordMapping")
struct ArticleRecordMappingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeFeed(_ context: ModelContext) -> Feed {
        let feed = Feed(name: "Example", identifier: "feed-1", type: .feedContent)
        context.insert(feed)
        return feed
    }

    @Test("Record built from an article carries the UID triple and image hashes")
    func fromArticle() throws {
        let context = try makeContext()
        let feed = makeFeed(context)
        let article = Article(title: "T", identifier: "a-1", url: "https://x/1")
        article.feed = feed
        article.blocks = [.image(ref: "yana-img://hash1", caption: [])]
        context.insert(article)

        let record = try #require(SyncedArticleRecord(article: article))
        #expect(record.uid == "feed-1|feedContent|a-1")
        #expect(record.imageHashes == ["hash1"])
        #expect(record.leadImageRef == "yana-img://hash1")
    }

    @Test("Applying a new record creates a linked article")
    func applyNew() throws {
        let context = try makeContext()
        let feed = makeFeed(context)
        let record = SyncedArticleRecord(
            uid: "feed-1|feedContent|a-9", feedIdentifier: "feed-1", aggregatorType: "feedContent",
            articleIdentifier: "a-9", title: "Nine", url: "https://x/9", author: "", summary: "",
            plainText: "nine", leadImageRef: "", iconURL: nil,
            date: Date(timeIntervalSince1970: 500), createdAt: Date(timeIntervalSince1970: 400),
            blockData: Data(), isStarred: false, tagNames: [], imageHashes: []
        )
        let feedsByKey = ["feed-1|feedContent": feed]
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil, feedsByKey: feedsByKey)
        #expect(article.identifier == "a-9")
        #expect(article.feed === feed)
        #expect(article.createdAt == Date(timeIntervalSince1970: 400))
    }

    @Test("Applying an existing UID keeps createdAt (first-writer-wins) but updates the body")
    func applyExistingKeepsCreatedAt() throws {
        let context = try makeContext()
        let feed = makeFeed(context)
        let existing = Article(title: "Old", identifier: "a-9", url: "https://x/9")
        existing.feed = feed
        existing.createdAt = Date(timeIntervalSince1970: 100)
        context.insert(existing)

        let record = SyncedArticleRecord(
            uid: "feed-1|feedContent|a-9", feedIdentifier: "feed-1", aggregatorType: "feedContent",
            articleIdentifier: "a-9", title: "New", url: "https://x/9", author: "", summary: "",
            plainText: "new", leadImageRef: "", iconURL: nil,
            date: Date(timeIntervalSince1970: 500), createdAt: Date(timeIntervalSince1970: 999),
            blockData: Data(), isStarred: false, tagNames: [], imageHashes: []
        )
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil,
                                               feedsByKey: ["feed-1|feedContent": feed])
        #expect(article.title == "New")                                   // last-writer-wins body
        #expect(article.createdAt == Date(timeIntervalSince1970: 100))    // first-writer-wins
    }

    @Test("A record whose feed is not yet present is created unlinked")
    func applyUnlinkedWhenFeedMissing() throws {
        let context = try makeContext()
        let record = SyncedArticleRecord(
            uid: "feed-x|feedContent|a-1", feedIdentifier: "feed-x", aggregatorType: "feedContent",
            articleIdentifier: "a-1", title: "Orphan", url: "https://x/1", author: "", summary: "",
            plainText: "", leadImageRef: "", iconURL: nil,
            date: .now, createdAt: .now, blockData: Data(), isStarred: false, tagNames: [], imageHashes: []
        )
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil, feedsByKey: [:])
        #expect(article.feed == nil)
        #expect(article.identifier == "a-1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleRecordMapping`
Expected: FAIL — `SyncedArticleRecord(article:)` / `ArticleRecordApply` not found. (If `Feed`'s initializer signature differs, adjust `makeFeed` to match `Feed.swift` — check its `init`.)

- [ ] **Step 3: Write the implementation**

Create `Yana/Services/ArticleSync/ArticleRecordMapping.swift`:

```swift
import Foundation
import SwiftData

extension SyncedArticleRecord {
    /// Build a record from a local article. Returns nil when the article has no feed (its triple
    /// can't be formed). Runs on the main actor — reads the non-Sendable `Article`.
    @MainActor
    init?(article: Article) {
        guard let feed = article.feed else { return nil }
        let blocks = article.blocks
        self.init(
            uid: ArticleUID.make(
                feedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType,
                articleIdentifier: article.identifier, date: article.date, title: article.title),
            feedIdentifier: feed.identifier,
            aggregatorType: feed.aggregatorType,
            articleIdentifier: article.identifier,
            title: article.title,
            url: article.url,
            author: article.author,
            summary: article.summary,
            plainText: article.plainText,
            leadImageRef: article.leadImageRef,
            iconURL: article.iconURL,
            date: article.date,
            createdAt: article.createdAt,
            blockData: article.blockData,
            isStarred: article.isStarred,
            tagNames: article.tags.map(\.name),
            imageHashes: ArticleImageRefs.hashes(in: blocks)
        )
    }
}

/// Upserts a single `SyncedArticleRecord` into local SwiftData. `createdAt` is first-writer-wins
/// (an existing article keeps its own); everything else is last-writer-wins. The feed is linked by
/// its `(identifier|aggregatorType)` key from `feedsByKey`, or left nil (held unlinked) when the
/// feed hasn't synced yet.
enum ArticleRecordApply {
    static func feedKey(feedIdentifier: String, aggregatorType: String) -> String {
        "\(feedIdentifier)|\(aggregatorType)"
    }

    @MainActor
    @discardableResult
    static func apply(
        _ record: SyncedArticleRecord,
        into context: ModelContext,
        starredTag: Tag?,
        feedsByKey: [String: Feed]
    ) -> Article {
        let feed = feedsByKey[feedKey(feedIdentifier: record.feedIdentifier, aggregatorType: record.aggregatorType)]

        // Find an existing local article with this UID's identifier under the same feed.
        let identifier = record.articleIdentifier
        let existing: Article?
        if let feed {
            existing = feed.articles.first { $0.identifier == identifier }
        } else {
            let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
            existing = (try? context.fetch(descriptor))?.first { $0.feed == nil }
        }

        let article = existing ?? {
            let created = Article(
                title: record.title, identifier: record.articleIdentifier, url: record.url,
                date: record.date, author: record.author, iconURL: record.iconURL, summary: record.summary)
            created.createdAt = record.createdAt       // first-writer value adopted on create
            context.insert(created)
            return created
        }()

        // Last-writer-wins body/metadata (createdAt intentionally untouched on update).
        article.title = record.title
        article.url = record.url
        article.author = record.author
        article.iconURL = record.iconURL
        article.summary = record.summary
        article.blockData = record.blockData
        article.plainText = record.plainText
        article.leadImageRef = record.leadImageRef
        article.date = record.date
        if let feed { article.feed = feed }

        // Tags: snapshot the feed's tags (the article's tagNames ride for reference/future use),
        // then reconcile Starred from the record.
        if let feed { article.tags = feed.tags }
        if let starredTag {
            article.setStarred(record.isStarred, using: starredTag)
        }
        return article
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleRecordMapping`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleSync/ArticleRecordMapping.swift YanaTests/ArticleSync/ArticleRecordMappingTests.swift
git commit -m "Add Article <-> SyncedArticleRecord mapping with FWW createdAt"
```

---

## Task 3: Store protocol, fake, and pull/reconcile

**Files:**
- Create: `Yana/Services/ArticleSync/ArticleZoneStore.swift`
- Create: `Yana/Services/ArticleSync/ArticleSyncService.swift`
- Create: `YanaTests/ArticleSync/FakeArticleZoneStore.swift`
- Create: `YanaTests/ArticleSync/ArticleSyncPullTests.swift`

**Interfaces:**
- Consumes: `SyncedArticleRecord`, `SyncedImageRecord`, `ArticleZoneChanges`, `ArticleRecordApply` (Tasks 1–2).
- Produces:
  - `protocol ArticleZoneStore: Sendable` with `func fetchChanges() async throws -> ArticleZoneChanges`, `func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws`, `func delete(articleUIDs: [String]) async throws`, `func fetchImage(hash: String) async throws -> SyncedImageRecord?`.
  - `@MainActor @Observable final class ArticleSyncService` with `init(store:context:settings:defaults:)`, `func pull() async`, `func reconcile(_ changes: ArticleZoneChanges)`, `func canonicalCreatedAt(forUID:) -> Date?`, `var lastSyncError: String?`.

- [ ] **Step 1: Write the failing test — the store protocol, fake, and pull reconcile**

Create `YanaTests/ArticleSync/FakeArticleZoneStore.swift`:

```swift
import Foundation
@testable import Yana

/// In-memory `ArticleZoneStore`. `articles` is keyed by UID; `images` by hash (write-once —
/// re-adding an existing hash is a no-op, proving image dedup). `pendingChanges` is what the next
/// `fetchChanges()` returns (simulating remote deltas).
@MainActor
final class FakeArticleZoneStore: ArticleZoneStore {
    var pendingChanges = ArticleZoneChanges.empty
    private(set) var articles: [String: SyncedArticleRecord] = [:]
    private(set) var images: [String: SyncedImageRecord] = [:]
    private(set) var deletedUIDs: [String] = []
    private(set) var uploadedImageHashes: [String] = []

    func fetchChanges() async throws -> ArticleZoneChanges {
        let changes = pendingChanges
        pendingChanges = .empty
        return changes
    }

    func upsert(articles newArticles: [SyncedArticleRecord], images newImages: [SyncedImageRecord]) async throws {
        for record in newArticles { articles[record.uid] = record }
        for image in newImages where images[image.hash] == nil {
            images[image.hash] = image
            uploadedImageHashes.append(image.hash)
        }
    }

    func delete(articleUIDs: [String]) async throws {
        for uid in articleUIDs { articles[uid] = nil; deletedUIDs.append(uid) }
    }

    func fetchImage(hash: String) async throws -> SyncedImageRecord? { images[hash] }

    /// Seed a record as if it already lived remotely (used to prime `pendingChanges`).
    func seedRemote(_ record: SyncedArticleRecord) {
        articles[record.uid] = record
        pendingChanges.articles.append(record)
    }
}
```

Create `YanaTests/ArticleSync/ArticleSyncPullTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSync pull")
struct ArticleSyncPullTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncPull.\(UUID().uuidString)")! }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext, enabled: Bool = true)
        -> (ArticleSyncService, AppSettings) {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = enabled
        let service = ArticleSyncService(store: store, context: context, settings: settings, defaults: suite())
        return (service, settings)
    }

    private func record(uid: String, feed: String, identifier: String, title: String,
                        createdAt: Date = .now) -> SyncedArticleRecord {
        SyncedArticleRecord(
            uid: uid, feedIdentifier: feed, aggregatorType: "feedContent", articleIdentifier: identifier,
            title: title, url: "https://x/\(identifier)", author: "", summary: "", plainText: title,
            leadImageRef: "", iconURL: nil, date: .now, createdAt: createdAt, blockData: Data(),
            isStarred: false, tagNames: [], imageHashes: [])
    }

    @Test("Pull materializes a remote article linked to its local feed")
    func pullCreatesLinked() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        try context.save()

        let store = FakeArticleZoneStore()
        store.seedRemote(record(uid: "f1|feedContent|a1", feed: "f1", identifier: "a1", title: "Hi"))
        let (service, _) = makeService(store, context)

        await service.pull()

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.feed === feed)
    }

    @Test("Pull skips a UID already present locally (dedup)")
    func pullDedupes() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        let existing = Article(title: "Old", identifier: "a1", url: "https://x/a1")
        existing.feed = feed
        context.insert(existing)
        try context.save()

        let store = FakeArticleZoneStore()
        store.seedRemote(record(uid: "f1|feedContent|a1", feed: "f1", identifier: "a1", title: "New"))
        let (service, _) = makeService(store, context)

        await service.pull()

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)                       // updated, not duplicated
        #expect(articles.first?.title == "New")
    }

    @Test("A tombstone removes the local article")
    func pullTombstone() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        let existing = Article(title: "Doomed", identifier: "a1", url: "https://x/a1")
        existing.feed = feed
        context.insert(existing)
        try context.save()

        let store = FakeArticleZoneStore()
        store.pendingChanges = ArticleZoneChanges(articles: [], deletedUIDs: ["f1|feedContent|a1"])
        let (service, _) = makeService(store, context)

        await service.pull()
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }

    @Test("canonicalCreatedAt reports the createdAt of a pulled record")
    func canonicalCreatedAt() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        try context.save()
        let store = FakeArticleZoneStore()
        let t = Date(timeIntervalSince1970: 777)
        store.seedRemote(record(uid: "f1|feedContent|a1", feed: "f1", identifier: "a1", title: "Hi", createdAt: t))
        let (service, _) = makeService(store, context)
        await service.pull()
        #expect(service.canonicalCreatedAt(forUID: "f1|feedContent|a1") == t)
    }

    @Test("Pull is a no-op when sync is disabled")
    func disabledNoOp() async throws {
        let context = try makeContext()
        let store = FakeArticleZoneStore()
        store.seedRemote(record(uid: "f1|feedContent|a1", feed: "f1", identifier: "a1", title: "Hi"))
        let (service, _) = makeService(store, context, enabled: false)
        await service.pull()
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSyncPull`
Expected: FAIL — `ArticleZoneStore` / `ArticleSyncService` not found. (Confirm `Feed(name:identifier:type:)` matches `Feed.swift`; adjust the fixture if the real initializer differs.)

- [ ] **Step 3: Write the store protocol**

Create `Yana/Services/ArticleSync/ArticleZoneStore.swift`:

```swift
import Foundation

/// Abstraction over the CloudKit `Articles` zone so `ArticleSyncService` is unit-testable without
/// CloudKit. The production adapter (`CloudKitArticleZoneStore`) wraps `CKSyncEngine`; tests use a
/// `FakeArticleZoneStore`.
protocol ArticleZoneStore: Sendable {
    /// Drain remote changes accumulated since the last call (upserts + tombstones).
    func fetchChanges() async throws -> ArticleZoneChanges
    /// Upsert article records and (write-once) image blobs.
    func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws
    /// Delete article records by UID (tombstone).
    func delete(articleUIDs: [String]) async throws
    /// Fetch a single image blob by hash, or nil when absent.
    func fetchImage(hash: String) async throws -> SyncedImageRecord?
}
```

- [ ] **Step 4: Write the service (pull half only)**

Create `Yana/Services/ArticleSync/ArticleSyncService.swift`:

```swift
import Foundation
import SwiftData
import CloudKit
import os

/// Orchestrates optional iCloud sync of full article content across devices. Gated on
/// `AppSettings.iCloudSyncEnabled`; every entry point returns immediately when off. Mirrors the
/// shape of `ConfigSyncService` (lazy store, main-actor, `lastSyncError`) but manages many records
/// in a dedicated zone via an `ArticleZoneStore`.
@MainActor
@Observable
final class ArticleSyncService {
    @ObservationIgnored private let makeStore: () -> ArticleZoneStore
    @ObservationIgnored private lazy var store: ArticleZoneStore = makeStore()
    private let context: ModelContext
    private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults

    /// UID → canonical `createdAt` learned from pulled records, so a locally aggregated insert with
    /// the same UID adopts the first-writer time instead of back-dating a fresh one.
    @ObservationIgnored private var canonicalCreatedAtByUID: [String: Date] = [:]

    private(set) var lastSyncError: String?

    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ArticleSync")

    static let shared = ArticleSyncService(
        store: CloudKitArticleZoneStore(),
        context: AppContainer.shared.mainContext,
        settings: AppSettings()
    )

    init(
        store: @autoclosure @escaping () -> ArticleZoneStore,
        context: ModelContext,
        settings: AppSettings,
        defaults: UserDefaults = .standard
    ) {
        self.makeStore = store
        self.context = context
        self.settings = settings
        self.defaults = defaults
    }

    // MARK: Pull

    /// Fetch remote changes and reconcile them into local state. No-op when sync is off.
    func pull() async {
        guard settings.iCloudSyncEnabled else { return }
        do {
            let changes = try await store.fetchChanges()
            reconcile(changes)
            lastSyncError = nil
        } catch {
            log.error("Article pull failed: \(String(describing: error))")
            lastSyncError = ConfigSyncService.describe(error)
        }
    }

    /// Merge a change set into local SwiftData. Public so tests can drive it directly.
    func reconcile(_ changes: ArticleZoneChanges) {
        let starredTag = starredTag()
        let feedsByKey = feedsByKey()

        for record in changes.articles {
            canonicalCreatedAtByUID[record.uid] = record.createdAt
            ArticleRecordApply.apply(record, into: context, starredTag: starredTag, feedsByKey: feedsByKey)
        }

        // Re-link any orphan (feed == nil) articles whose stored identity now matches a present
        // feed — covers records that synced before their feed arrived via config sync.
        relinkOrphans(feedsByKey: feedsByKey, starredTag: starredTag)

        if !changes.deletedUIDs.isEmpty {
            let deleted = Set(changes.deletedUIDs)
            let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
            for article in all {
                guard let uid = ArticleUID.make(for: article), deleted.contains(uid) else { continue }
                canonicalCreatedAtByUID[uid] = nil
                context.delete(article)
            }
        }
        try? context.save()
    }

    /// The canonical (first-writer) createdAt for a UID, if a pull has seen it.
    func canonicalCreatedAt(forUID uid: String) -> Date? { canonicalCreatedAtByUID[uid] }

    // MARK: Helpers

    /// Link orphan articles (feed == nil) to a now-present feed by their stored sync identity.
    private func relinkOrphans(feedsByKey: [String: Feed], starredTag: Tag?) {
        let orphans = (try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.feed == nil }))) ?? []
        for article in orphans where !article.syncFeedIdentifier.isEmpty {
            let key = ArticleRecordApply.feedKey(
                feedIdentifier: article.syncFeedIdentifier, aggregatorType: article.syncAggregatorType)
            guard let feed = feedsByKey[key] else { continue }
            let wasStarred = article.isStarred      // read BEFORE tags are overwritten (isStarred is computed from tags)
            article.feed = feed
            article.tags = feed.tags
            if wasStarred, let starredTag, !article.tags.contains(where: { $0.id == starredTag.id }) {
                article.tags.append(starredTag)
            }
        }
    }

    private func feedsByKey() -> [String: Feed] {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        var map: [String: Feed] = [:]
        for feed in feeds {
            map[ArticleRecordApply.feedKey(feedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType)] = feed
        }
        return map
    }

    private func starredTag() -> Tag? {
        Tag.ensureBuiltIns(in: context)
        return (try? context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })))?.first
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSyncPull`
Expected: PASS (6 tests). This will fail to compile until Task 4 adds `CloudKitArticleZoneStore` referenced by `shared`. **To keep this task self-contained, add a stub now** and flesh it out in Task 9:

Create `Yana/Services/ArticleSync/CloudKitArticleZoneStore.swift` (temporary stub — replaced in Task 9):

```swift
import Foundation

/// Placeholder production store; real `CKSyncEngine` implementation lands in Task 9.
@MainActor
final class CloudKitArticleZoneStore: ArticleZoneStore {
    func fetchChanges() async throws -> ArticleZoneChanges { .empty }
    func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws {}
    func delete(articleUIDs: [String]) async throws {}
    func fetchImage(hash: String) async throws -> SyncedImageRecord? { nil }
}
```

Re-run the test command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/ArticleSync/ArticleZoneStore.swift Yana/Services/ArticleSync/ArticleSyncService.swift Yana/Services/ArticleSync/CloudKitArticleZoneStore.swift YanaTests/ArticleSync/FakeArticleZoneStore.swift YanaTests/ArticleSync/ArticleSyncPullTests.swift
git commit -m "Add ArticleZoneStore protocol and ArticleSyncService pull/reconcile"
```

---

## Task 4: Push + image sync (both directions)

**Files:**
- Modify: `Yana/Utilities/ImageStore.swift` (add accessors)
- Modify: `Yana/Services/ArticleSync/ArticleSyncService.swift` (add push + image hydrate)
- Create: `YanaTests/ArticleSync/ArticleSyncPushTests.swift`
- Create: `YanaTests/ArticleSync/ArticleSyncImageTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–3, `ImageStore`.
- Produces:
  - `ImageStore`: `func fileExists(forHash:) -> Bool`, `func rawData(forHash:) -> Data?`, `func recordedExt(forHash:) -> String?`.
  - `ArticleSyncService`: `func push(uids: [String]) async` (upload the given local articles + their images), `func pushAll() async` (migration full-push), `func hydrateImages(for records: [SyncedArticleRecord]) async` (fetch missing blobs into `ImageStore`). `reconcile` triggers image hydration for incoming records.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/ArticleSync/ArticleSyncPushTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSync push")
struct ArticleSyncPushTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncPush.\(UUID().uuidString)")! }
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }
    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext, enabled: Bool = true)
        -> ArticleSyncService {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = enabled
        return ArticleSyncService(store: store, context: context, settings: settings, defaults: suite())
    }

    @Test("pushAll uploads every local article by UID")
    func pushAllUploads() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        for i in 1...3 {
            let a = Article(title: "T\(i)", identifier: "a\(i)", url: "https://x/\(i)")
            a.feed = feed
            context.insert(a)
        }
        try context.save()
        let store = FakeArticleZoneStore()
        let service = makeService(store, context)

        await service.pushAll()
        #expect(Set(store.articlesUIDsForTest) == ["f1|feedContent|a1", "f1|feedContent|a2", "f1|feedContent|a3"])
    }

    @Test("push is a no-op when sync is disabled")
    func disabledNoOp() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        let a = Article(title: "T", identifier: "a1", url: "https://x/1"); a.feed = feed; context.insert(a)
        try context.save()
        let store = FakeArticleZoneStore()
        let service = makeService(store, context, enabled: false)
        await service.pushAll()
        #expect(store.articlesUIDsForTest.isEmpty)
    }
}
```

Add this accessor to `FakeArticleZoneStore` (in `FakeArticleZoneStore.swift`):

```swift
    var articlesUIDsForTest: [String] { Array(articles.keys) }
```

Create `YanaTests/ArticleSync/ArticleSyncImageTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSync images")
struct ArticleSyncImageTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncImg.\(UUID().uuidString)")! }
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }
    /// A throwaway on-disk ImageStore in a unique temp dir.
    private func makeImageStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgtest-\(UUID().uuidString)")
        return ImageStore(directory: dir)
    }
    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext, _ images: ImageStore)
        -> ArticleSyncService {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = true
        return ArticleSyncService(store: store, context: context, settings: settings, defaults: suite(), imageStore: images)
    }

    @Test("Pushing an article with a local image uploads the blob once")
    func pushUploadsImageOnce() async throws {
        let images = makeImageStore()
        let bytes = Data("PNGDATA".utf8)
        let hash = await images.storeData(bytes, ext: "png")

        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        let a = Article(title: "T", identifier: "a1", url: "https://x/1")
        a.feed = feed
        a.blocks = [.image(ref: "yana-img://\(hash)", caption: [])]
        context.insert(a)
        let b = Article(title: "T2", identifier: "a2", url: "https://x/2")   // references same image
        b.feed = feed
        b.blocks = [.image(ref: "yana-img://\(hash)", caption: [])]
        context.insert(b)
        try context.save()

        let store = FakeArticleZoneStore()
        let service = makeService(store, context, images)
        await service.pushAll()

        #expect(store.uploadedImageHashes == [hash])         // uploaded exactly once despite two refs
    }

    @Test("Reconciling a record hydrates a missing image into the local store")
    func pullHydratesImage() async throws {
        let images = makeImageStore()
        let bytes = Data("REMOTEPNG".utf8)
        // Compute the hash the same way ImageStore would, by storing then removing? Simpler: push
        // from a source store to learn the hash, then hydrate into a fresh store.
        let sourceImages = makeImageStore()
        let hash = await sourceImages.storeData(bytes, ext: "png")

        let store = FakeArticleZoneStore()
        try await store.upsert(articles: [], images: [SyncedImageRecord(hash: hash, ext: "png", data: bytes)])

        let context = try makeContext()
        let service = makeService(store, context, images)
        let record = SyncedArticleRecord(
            uid: "f1|feedContent|a1", feedIdentifier: "f1", aggregatorType: "feedContent", articleIdentifier: "a1",
            title: "T", url: "https://x/1", author: "", summary: "", plainText: "", leadImageRef: "yana-img://\(hash)",
            iconURL: nil, date: .now, createdAt: .now, blockData: Data(), isStarred: false, tagNames: [],
            imageHashes: [hash])
        await service.hydrateImages(for: [record])

        #expect(await images.fileExists(forHash: hash))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSyncPush -only-testing:YanaTests/ArticleSyncImage`
Expected: FAIL — `pushAll`, `hydrateImages`, `imageStore:` init param, and the `ImageStore` accessors don't exist.

- [ ] **Step 3: Add ImageStore accessors**

In `Yana/Utilities/ImageStore.swift`, add these methods inside the `actor ImageStore` body (they need private `extensions`/`directory`):

```swift
    /// Whether a blob for this hash already exists on disk.
    func fileExists(forHash hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forHash: hash).path)
    }

    /// Raw bytes for a stored hash, or nil when absent. Used by article sync to upload the blob.
    func rawData(forHash hash: String) -> Data? {
        let url = fileURL(forHash: hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The recorded file extension for a hash (defaults to "img" when unknown).
    func recordedExt(forHash hash: String) -> String { extensions[hash] ?? "img" }
```

- [ ] **Step 4: Add push + image hydration to `ArticleSyncService`**

In `ArticleSyncService.swift`, add an `imageStore` dependency and the push/hydrate methods. Change the init and `shared`:

```swift
    @ObservationIgnored private let imageStore: ImageStore
```

Update `init` to accept `imageStore: ImageStore = .shared` (add as the last parameter) and assign it; update `static let shared` to pass `imageStore: .shared` (it's the default, so no change needed there beyond leaving it out).

Add the push + hydrate methods:

```swift
    // MARK: Push

    /// Upload every local article (migration / enable path).
    func pushAll() async {
        guard settings.iCloudSyncEnabled else { return }
        let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        await pushArticles(all)
    }

    /// Upload the local articles with the given UIDs (post-aggregation path).
    func push(uids: [String]) async {
        guard settings.iCloudSyncEnabled, !uids.isEmpty else { return }
        let wanted = Set(uids)
        let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        let matching = all.filter { wanted.contains(uid(for: $0)) }
        await pushArticles(matching)
    }

    private func pushArticles(_ articles: [Article]) async {
        var records: [SyncedArticleRecord] = []
        var imageHashes = Set<String>()
        for article in articles {
            guard let record = SyncedArticleRecord(article: article) else { continue }
            records.append(record)
            imageHashes.formUnion(record.imageHashes)
        }
        guard !records.isEmpty else { return }

        // Gather the referenced image blobs from the local store (write-once dedup by hash).
        var images: [SyncedImageRecord] = []
        for hash in imageHashes {
            if let data = await imageStore.rawData(forHash: hash) {
                let ext = await imageStore.recordedExt(forHash: hash)
                images.append(SyncedImageRecord(hash: hash, ext: ext, data: data))
            }
        }

        do {
            try await store.upsert(articles: records, images: images)
            for record in records { canonicalCreatedAtByUID[record.uid] = record.createdAt }
            lastSyncError = nil
        } catch {
            log.error("Article push failed: \(String(describing: error))")
            lastSyncError = ConfigSyncService.describe(error)
        }
    }

    // MARK: Image hydration

    /// Download any image blobs referenced by the given records that are missing locally, writing
    /// them into the local `ImageStore` so `yana-img://` refs resolve. Failures are non-fatal — a
    /// body still renders, just without that image until a later pull.
    func hydrateImages(for records: [SyncedArticleRecord]) async {
        var needed = Set<String>()
        for record in records { needed.formUnion(record.imageHashes) }
        for hash in needed where !(await imageStore.fileExists(forHash: hash)) {
            if let image = try? await store.fetchImage(hash: hash) {
                _ = await imageStore.storeData(image.data, ext: image.ext)
            }
        }
    }
```

Wire hydration into `reconcile` — after the `for record in changes.articles` loop and before `try? context.save()`, capture the records and kick off hydration without blocking the save:

```swift
        // Hydrate referenced images off the reconcile path (best-effort, non-blocking).
        let incoming = changes.articles
        if !incoming.isEmpty {
            Task { [weak self] in await self?.hydrateImages(for: incoming) }
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSyncPush -only-testing:YanaTests/ArticleSyncImage`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Utilities/ImageStore.swift Yana/Services/ArticleSync/ArticleSyncService.swift YanaTests/ArticleSync/FakeArticleZoneStore.swift YanaTests/ArticleSync/ArticleSyncPushTests.swift YanaTests/ArticleSync/ArticleSyncImageTests.swift
git commit -m "Add article-sync push and content-addressed image sync"
```

---

## Task 5: Pre-insert re-check (canonical createdAt adoption) + populate stored feed identity

**Files:**
- Modify: `Yana/Services/ArticleUpsert.swift`
- Modify: `Yana/Services/AggregationService.swift`
- Create: `YanaTests/ArticleSync/PreInsertRecheckTests.swift`

**Interfaces:**
- Consumes: `ArticleSyncService.canonicalCreatedAt(forUID:)`, `ArticleUID`, `ArticleUID.make(for:)`, `Article.syncFeedIdentifier`/`syncAggregatorType`.
- Produces: `ArticleUpsert.apply(...)` gains a trailing `canonicalCreatedAt: (String) -> Date? = { _ in nil }` parameter; when it returns a non-nil date for a to-be-inserted article's UID, that date is used as `createdAt` instead of the jittered back-date. `AggregationService` pulls article sync before a run and pushes new UIDs after, and passes the canonical-createdAt lookup into every `ArticleUpsert.apply` call.

**Also in this task — populate stored feed identity (from the mid-Task-2 design decision):** `ArticleUpsert.apply` must set `article.syncFeedIdentifier = feed.identifier` and `article.syncAggregatorType = feed.aggregatorType` on **both** the insert and update branches (so every imported article carries its origin, enabling sync UID derivation and orphan re-linking). Add a test asserting a freshly upserted article has these fields set. And replace `pushRecentlyChanged`'s inline UID derivation with `ArticleUID.make(for:)` (skip articles it returns nil for).

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSync/PreInsertRecheckTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Pre-insert re-check")
struct PreInsertRecheckTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }

    @Test("A new insert adopts the canonical createdAt when the sync layer knows the UID")
    func adoptsCanonical() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        let canonical = Date(timeIntervalSince1970: 12345)

        let aggregated = [AggregatedArticle(
            title: "T", identifier: "a1", url: "https://x/1", rawContent: "", content: "<p>hi</p>",
            date: Date(timeIntervalSince1970: 500), author: "", iconURL: nil)]

        let inserted = ArticleUpsert.apply(
            aggregated, to: feed, starredTag: nil, context: context, now: .now,
            jitter: { 60 },      // would back-date by 60s if canonical were absent
            canonicalCreatedAt: { uid in uid == "f1|feedContent|a1" ? canonical : nil })

        #expect(inserted == 1)
        let article = try #require(feed.articles.first)
        #expect(article.createdAt == canonical)     // canonical adopted, not now-60
    }

    @Test("Without a canonical hit the insert back-dates by jitter as before")
    func fallsBackToJitter() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)
        let now = Date(timeIntervalSince1970: 10_000)
        let aggregated = [AggregatedArticle(
            title: "T", identifier: "a2", url: "https://x/2", rawContent: "", content: "<p>hi</p>",
            date: now, author: "", iconURL: nil)]
        _ = ArticleUpsert.apply(aggregated, to: feed, starredTag: nil, context: context, now: now,
                                jitter: { 60 }, canonicalCreatedAt: { _ in nil })
        let article = try #require(feed.articles.first)
        #expect(article.createdAt == now.addingTimeInterval(-60))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PreInsertRecheck`
Expected: FAIL — `apply` has no `canonicalCreatedAt:` parameter.

- [ ] **Step 3: Add the parameter to `ArticleUpsert.apply`**

In `Yana/Services/ArticleUpsert.swift`, add the parameter to the signature (after `blocksFor`):

```swift
        blocksFor: (AggregatedArticle) -> [Block] = ArticleUpsert.defaultBlocks,
        canonicalCreatedAt: (String) -> Date? = { _ in nil }
```

In the insert branch, replace the back-date line:

```swift
                article.createdAt = now.addingTimeInterval(-jitter())
```

with:

```swift
                // Adopt the canonical (first-writer) createdAt when article sync already knows this
                // UID — i.e. another device created it in the meantime — so ordering stays stable
                // across devices. Otherwise back-date by jitter as usual.
                let uid = ArticleUID.make(
                    feedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType,
                    articleIdentifier: item.identifier, date: item.date, title: item.title)
                article.createdAt = canonicalCreatedAt(uid) ?? now.addingTimeInterval(-jitter())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PreInsertRecheck`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire AggregationService — pull before, push after, canonical lookup**

In `AggregationService.swift`:

Add a stored dependency (default to the shared service) near the other stored properties:

```swift
    private let articleSync: ArticleSyncService
```

Add to `init` (last parameter) `articleSync: ArticleSyncService = .shared` and assign `self.articleSync = articleSync`.

At the **start** of `updateAll()` (before the `descriptor` fetch) and `update(feed:)` (before `aggregate`), drain remote changes so the run upserts against the freshest local state:

```swift
        await articleSync.pull()
```

Pass the canonical lookup into every `ArticleUpsert.apply` call in this file (there are calls in `upsert`, `forceReload(article:)`). For each, add the trailing argument:

```swift
            canonicalCreatedAt: { [articleSync] uid in articleSync.canonicalCreatedAt(forUID: uid) }
```

After a run completes, push the resulting local articles. In `updateAll()`, replace the tail:

```swift
        cleanupAndSave()
        return inserted
```

with:

```swift
        cleanupAndSave()
        await pushRecentlyChanged()
        return inserted
```

In `update(feed:)`, `forceReload(feed:)`, `forceReload(article:)`, and `summarize(_:)`, add `await pushRecentlyChanged()` right before their `return`. Add the helper:

```swift
    /// Push all local articles' current state to article sync. Simpler and safe: article sync
    /// dedups by UID and skips unchanged records at the CloudKit layer, and this runs only after a
    /// user/background refresh, not per article.
    private func pushRecentlyChanged() async {
        let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        await articleSync.push(uids: all.compactMap { ArticleUID.make(for: $0) })
    }
```

> Note: pushing all UIDs each run is intentional for v1 simplicity; the CloudKit adapter only transmits records whose change-tag differs, so unchanged articles cost nothing on the wire. A future optimization can track the exact touched UIDs per run.

- [ ] **Step 6: Run the full aggregation test suite to confirm no regressions**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests`
Expected: PASS (existing aggregation tests still green; new tests green). If a pre-existing test constructs `AggregationService` positionally, the new trailing defaulted `articleSync` parameter keeps it source-compatible.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/ArticleUpsert.swift Yana/Services/AggregationService.swift YanaTests/ArticleSync/PreInsertRecheckTests.swift
git commit -m "Adopt canonical createdAt on insert; pull-before/push-after aggregation"
```

---

## Task 6: Retention & deletion propagation

**Files:**
- Modify: `Yana/Services/RetentionCleanup.swift`
- Modify: `Yana/Services/AggregationService.swift`
- Modify: `Yana/Services/ArticleSync/ArticleSyncService.swift` (add `deleteRemote(uids:)`)
- Create: `YanaTests/ArticleSync/ArticleSyncRetentionTests.swift`

**Interfaces:**
- Produces:
  - `RetentionCleanup.run(...)` returns `[String]` — the UIDs it deleted.
  - `ArticleSyncService.deleteRemote(uids: [String]) async` — tombstone records in the zone (gated, no-op when off/empty).
  - `AggregationService.cleanupAndSave()` collects deleted UIDs and, when not passive, propagates them via `deleteRemote`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSync/ArticleSyncRetentionTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Retention deletion propagation")
struct ArticleSyncRetentionTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }

    @Test("RetentionCleanup returns the UIDs it deleted, skipping starred")
    func returnsDeletedUIDs() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        let starredTag = try #require((try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn }))).first)
        let feed = Feed(name: "F", identifier: "f1", type: .feedContent)
        context.insert(feed)

        let old = Article(title: "Old", identifier: "a1", url: "https://x/1")
        old.feed = feed; old.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(old)

        let oldStarred = Article(title: "Keep", identifier: "a2", url: "https://x/2")
        oldStarred.feed = feed; oldStarred.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(oldStarred)
        oldStarred.setStarred(true, using: starredTag)
        try context.save()

        let deleted = RetentionCleanup.run(context: context, retentionDays: 30, now: Date(timeIntervalSince1970: 60 * 86_400))
        #expect(deleted == ["f1|feedContent|a1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSyncRetention`
Expected: FAIL — `RetentionCleanup.run` returns `Void`.

- [ ] **Step 3: Make `RetentionCleanup.run` return deleted UIDs**

Replace `Yana/Services/RetentionCleanup.swift` body:

```swift
import Foundation
import SwiftData

/// Deletes articles older than the retention window, except those the user has Starred, and
/// returns the canonical UIDs of everything it deleted so the caller can propagate the deletion to
/// iCloud. (Spec §2 — age is the only cleanup criterion; there is no read/unread state.)
enum RetentionCleanup {
    @MainActor
    @discardableResult
    static func run(context: ModelContext, retentionDays: Int, now: Date) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.createdAt < cutoff })
        let candidates = (try? context.fetch(descriptor)) ?? []
        var deletedUIDs: [String] = []
        for article in candidates where !article.isStarred {
            if let uid = ArticleUID.make(for: article) { deletedUIDs.append(uid) }
            context.delete(article)
        }
        return deletedUIDs
    }
}
```

- [ ] **Step 4: Add `deleteRemote` to `ArticleSyncService`**

In `ArticleSyncService.swift`:

```swift
    /// Tombstone the given UIDs in the zone. Gated; no-op when off or empty.
    func deleteRemote(uids: [String]) async {
        guard settings.iCloudSyncEnabled, !uids.isEmpty else { return }
        do {
            try await store.delete(articleUIDs: uids)
            for uid in uids { canonicalCreatedAtByUID[uid] = nil }
            lastSyncError = nil
        } catch {
            log.error("Article delete failed: \(String(describing: error))")
            lastSyncError = ConfigSyncService.describe(error)
        }
    }
```

- [ ] **Step 5: Propagate deletions from `cleanupAndSave`**

In `AggregationService.swift`, replace `cleanupAndSave()`:

```swift
    private func cleanupAndSave() {
        let settings = AppSettings()
        // Passive devices never run retention or initiate deletions — they only mirror.
        guard !settings.isPassiveDevice else { return }
        let deletedUIDs = RetentionCleanup.run(context: context, retentionDays: settings.retentionDays, now: now())
        try? context.save()
        if !deletedUIDs.isEmpty {
            Task { [articleSync] in await articleSync.deleteRemote(uids: deletedUIDs) }
        }
    }
```

> `AppSettings.isPassiveDevice` lands in Task 7; this references it ahead of time, so implement Task 7 before building. If you build between tasks, temporarily gate on `false` and switch to `settings.isPassiveDevice` in Task 7.

- [ ] **Step 6: Run tests**

Run (after Task 7's `isPassiveDevice` exists, or with the temporary `false`): `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSyncRetention`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/RetentionCleanup.swift Yana/Services/ArticleSync/ArticleSyncService.swift Yana/Services/AggregationService.swift YanaTests/ArticleSync/ArticleSyncRetentionTests.swift
git commit -m "Propagate retention deletions to iCloud; skip on passive devices"
```

---

## Task 7: Passive device toggle

**Files:**
- Modify: `Yana/Models/AppSettings.swift`
- Modify: `Yana/Services/BackgroundRefreshManager.swift`
- Create: `YanaTests/ArticleSync/PassiveDeviceTests.swift`

**Interfaces:**
- Produces: `AppSettings.isPassiveDevice: Bool` (device-local, never synced, default false). `BackgroundRefreshManager.register()`/`schedule()`/`runNow()` (and the Mac loop) become no-ops when passive.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSync/PassiveDeviceTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Passive device")
struct PassiveDeviceTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "Passive.\(UUID().uuidString)")! }

    @Test("isPassiveDevice defaults to false and persists")
    func persists() {
        let d = suite()
        let s = AppSettings(defaults: d)
        #expect(s.isPassiveDevice == false)
        s.isPassiveDevice = true
        #expect(AppSettings(defaults: d).isPassiveDevice == true)
    }

    @Test("isPassiveDevice is absent from the synced settings payload")
    func notSynced() {
        let d = suite()
        let s = AppSettings(defaults: d)
        s.isPassiveDevice = true
        let data = s.exportSyncedSettings()
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("isPassiveDevice"))
        #expect(!json.contains("PassiveDevice"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PassiveDevice`
Expected: FAIL — `isPassiveDevice` not found.

- [ ] **Step 3: Add the setting**

In `Yana/Models/AppSettings.swift`, add to the `Key` enum near the iCloud keys:

```swift
        static let isPassiveDevice = "settings.isPassiveDevice"
```

Add the property in the `// MARK: iCloud Sync` section:

```swift
    /// When on, this device is a passive iCloud mirror: it never runs background aggregation
    /// (gated in `BackgroundRefreshManager`). Retention cleanup is also skipped on passive devices
    /// (gated in `AggregationService` — see Task 6). Manual fetches still work. Device-local —
    /// never included in the synced payload (it describes this device's role).
    var isPassiveDevice: Bool {
        get { access(keyPath: \.isPassiveDevice); return defaults.bool(forKey: Key.isPassiveDevice) }
        set { withMutation(keyPath: \.isPassiveDevice) { defaults.set(newValue, forKey: Key.isPassiveDevice) } }
    }
```

(`SyncedSettings` gets no field for it, so `notSynced` passes by construction.)

- [ ] **Step 4: Gate BackgroundRefreshManager**

In `Yana/Services/BackgroundRefreshManager.swift`, guard the public entry points. At the top of `register()`, `schedule()`, and `runNow()` (and, on Mac, wherever the repeating loop is armed), add:

```swift
        guard !AppSettings().isPassiveDevice else { return }
```

(Place the guard as the first line of each method. Read the file to confirm exact method names — `register`, `schedule`, `runNow`, and the Mac loop starter — and add the guard to each.)

- [ ] **Step 5: Run tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PassiveDevice`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Services/BackgroundRefreshManager.swift YanaTests/ArticleSync/PassiveDeviceTests.swift
git commit -m "Add device-local passive-device toggle; skip background refresh when passive"
```

---

## Task 8: Timeline position via UID; retire starredData

**Files:**
- Modify: `Yana/Models/AppSettings.swift`
- Modify: `Yana/Services/ConfigSyncService.swift`
- Modify: `Yana/Reader/ReaderHostView.swift`
- Modify: `Yana/Reader/Mac/TimelineModel.swift`
- Modify: `YanaTests/SettingsSyncTests.swift` (existing) and/or `YanaTests/ConfigSyncServiceTests.swift`

**Interfaces:**
- `SyncedSettings.timelinePosition: Double?` → `timelineAnchorUID: String?` (carries the anchored article's `identifier` — exact within the now-identical timeline).
- Remove `syncTimelinePositionEnabled`, `timelinePositionTimestamp`, and the `TimelineClosest` closest-match path.
- `ConfigDocument` loses `starredData`; `buildDocument`/`reconcile` stop reading/writing it. (Starred now rides on `SyncedArticle`.)

- [ ] **Step 1: Write/adjust the failing test**

Read `YanaTests/SettingsSyncTests.swift` first to match its style. Add to it:

```swift
    @Test("Synced settings carry the timeline anchor UID, not a timestamp")
    func anchorUIDSynced() {
        let d = UserDefaults(suiteName: "SettingsSync.anchor.\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.iCloudSyncEnabled = true
        s.timelineAnchorIdentifier = "post-42"
        let json = String(data: s.exportSyncedSettings(), encoding: .utf8) ?? ""
        #expect(json.contains("timelineAnchorUID"))
        #expect(json.contains("post-42"))
        #expect(!json.contains("timelinePosition"))
    }

    @Test("Applying an anchor UID sets the local timeline anchor identifier")
    func applyAnchorUID() {
        let d = UserDefaults(suiteName: "SettingsSync.applyAnchor.\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        let payload = #"{"timelineAnchorUID":"post-7"}"#.data(using: .utf8)!
        s.applySyncedSettings(payload)
        #expect(s.timelineAnchorIdentifier == "post-7")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SettingsSync`
Expected: FAIL — `timelineAnchorUID` doesn't exist; export still emits `timelinePosition`.

- [ ] **Step 3: Swap the field in `AppSettings`**

In `SyncedSettings`, replace the `timelinePosition` property with:

```swift
        /// The anchored article's identifier (exact within the now-identical timeline). Present only
        /// when this device has iCloud sync on; a receiving device jumps to that exact article.
        var timelineAnchorUID: String?
```

In `exportSyncedSettings()`, replace the `timelinePosition:` argument with:

```swift
            timelineAnchorUID: iCloudSyncEnabled ? timelineAnchorIdentifier : nil
```

In `applySyncedSettings(_:)`, replace the `timelinePosition` block with:

```swift
        if let uid = decoded.timelineAnchorUID {
            timelineAnchorIdentifier = uid
            NotificationCenter.default.post(name: Self.timelinePositionDidChange, object: self)
        }
```

Delete the `syncTimelinePositionEnabled` property, its `Key`, and the `timelinePositionTimestamp` property + its `Key` (`timelinePositionTimestamp`). Keep `timelineAnchorIdentifier` and the `timelinePositionDidChange` notification (now posted on UID apply).

- [ ] **Step 4: Remove `starredData` from `ConfigDocument`**

In `Yana/Services/ConfigSyncService.swift`:
- Delete the `starredData` field from `ConfigDocument`, the `encodeStarred`/`decodeStarred` helpers, and the `starred*` lines from `CloudKitConfigStore.save`/`document(from:)`.
- In `buildDocument()`, drop `starredData:`.
- In `reconcile(_:)`, delete step 5 (the `starred.update(...)` / `applyToLocalArticles`) — starred now arrives via article sync.
- Update the `ConfigDocument` initializer call sites accordingly.

> Keep the `starred` dependency parameter on `ConfigSyncService.init` for now (harmless) OR remove it and update `ConfigSyncServiceTests` construction — either is fine; removing is cleaner. If you remove it, drop `starred` from `makeService` in `ConfigSyncServiceTests.swift`.

- [ ] **Step 5: Update the reader position paths**

In `Yana/Reader/ReaderHostView.swift`:
- In the anchor-restore block (around the `TimelineBootstrap.resolve` call), delete the `if settings.syncTimelinePositionEnabled … TimelineClosest …` branch and keep only:
  ```swift
  appState.currentIndex = resolved.anchorIndex
  ```
- Replace `jumpToSyncedTimelinePosition()` body with an exact-identifier jump:
  ```swift
  private func jumpToSyncedTimelinePosition() {
      guard didRestoreAnchor,
            let uid = settings.timelineAnchorIdentifier,
            let i = filteredArticles.firstIndex(where: { $0.identifier == uid }) else { return }
      appState.currentIndex = i
  }
  ```
- In `saveAnchor(at:)`, replace the position-sync tail:
  ```swift
      settings.timelineAnchorIdentifier = articles[index].identifier
      ConfigSyncService.shared.requestPush()
  ```
  (Drop the `syncTimelinePositionEnabled` guard and the `timelinePositionTimestamp` line. `requestPush` is already gated on `iCloudSyncEnabled` and debounced.)

In `Yana/Reader/Mac/TimelineModel.swift`: no position-timestamp code exists there beyond `requestPush()` on star; leave as-is. If it references `syncTimelinePositionEnabled`/`timelinePositionTimestamp` anywhere, remove those references the same way. (Grep to confirm: `grep -n "syncTimelinePosition\|timelinePositionTimestamp\|TimelineClosest" Yana/Reader/Mac/TimelineModel.swift`.)

Delete `TimelineClosest` if it's now unused: `grep -rn "TimelineClosest" Yana` — if the only hits were the ones you just removed, delete its source file and any test.

- [ ] **Step 6: Run tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SettingsSync -only-testing:YanaTests/ConfigSyncService`
Expected: PASS. Then a full build to catch dangling references: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Sync timeline position as exact anchor UID; retire starredData from config sync"
```

---

## Task 9: Production CKSyncEngine store + launch/UI wiring + migration

**Files:**
- Modify: `Yana/Services/ArticleSync/CloudKitArticleZoneStore.swift` (replace stub)
- Modify: `Yana/YanaApp.swift`
- Modify: `Yana/Views/Config/SettingsScreenView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ArticleZoneStore`, all record types.
- Produces: a working `CloudKitArticleZoneStore` conforming to `ArticleZoneStore`; article sync started/pulled at launch and on toggle-enable; a passive toggle in Settings replacing the position toggle.

> **Verification note:** The `CKSyncEngine` adapter can't be unit-tested (like the existing `CloudKitConfigStore`, which also has no unit test). It is verified by compiling and by the manual two-device check at the end. Its correctness rests on the `ArticleZoneStore` contract already covered by the fake.

- [ ] **Step 1: Implement `CloudKitArticleZoneStore`**

Replace `Yana/Services/ArticleSync/CloudKitArticleZoneStore.swift`:

```swift
import Foundation
import CloudKit
import os

/// Production `ArticleZoneStore` backed by `CKSyncEngine` over a dedicated `Articles` record zone in
/// the app's private database. `CKSyncEngine` owns change-token/state persistence and retry; this
/// adapter translates between our `Sendable` record structs and `CKRecord`s and buffers incoming
/// remote changes for `fetchChanges()` to drain.
@MainActor
final class CloudKitArticleZoneStore: NSObject, ArticleZoneStore, CKSyncEngineDelegate {
    static let articleRecordType = "SyncedArticle"
    static let imageRecordType = "SyncedImage"
    static let zoneName = "Articles"

    private let container: CKContainer
    private lazy var database = container.privateCloudDatabase
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitArticleZoneStore.zoneName)
    private let defaults: UserDefaults
    private let stateKey = "articleSync.engineState"

    private var _engine: CKSyncEngine?
    private var incoming = ArticleZoneChanges.empty
    private var pendingImageUploads: [String: SyncedImageRecord] = [:]   // hash -> record awaiting send
    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ArticleSync")

    init(container: CKContainer = CKContainer(identifier: "iCloud.de.fa-krug.Yana"),
         defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        super.init()
    }

    private func engine() -> CKSyncEngine {
        if let _engine { return _engine }
        var config = CKSyncEngine.Configuration(
            database: database, stateSerialization: savedState(), delegate: self)
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        _engine = engine
        return engine
    }

    // MARK: ArticleZoneStore

    func fetchChanges() async throws -> ArticleZoneChanges {
        try await engine().fetchChanges()
        let drained = incoming
        incoming = .empty
        return drained
    }

    func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws {
        for image in images { pendingImageUploads[image.hash] = image }
        let ids = articles.map { CKRecord.ID(recordName: $0.uid, zoneID: zoneID) }
            + images.map { CKRecord.ID(recordName: $0.hash, zoneID: zoneID) }
        articleRecordCache = Dictionary(uniqueKeysWithValues: articles.map { ($0.uid, $0) })
        engine().state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        try await engine().sendChanges()
    }

    func delete(articleUIDs: [String]) async throws {
        let ids = articleUIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        engine().state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
        try await engine().sendChanges()
    }

    func fetchImage(hash: String) async throws -> SyncedImageRecord? {
        let id = CKRecord.ID(recordName: hash, zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            return Self.imageRecord(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // Cache of records to serialize when the engine asks for a batch (recordName -> struct).
    private var articleRecordCache: [String: SyncedArticleRecord] = [:]

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            defaults.set(try? update.stateSerialization.data(), forKey: stateKey)
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let record = modification.record
                if record.recordType == Self.articleRecordType,
                   let article = Self.articleRecord(from: record) {
                    incoming.articles.append(article)
                }
            }
            for deletion in changes.deletions where deletion.recordType == Self.articleRecordType {
                incoming.deletedUIDs.append(deletion.recordID.recordName)
            }
        case .sentRecordZoneChanges, .sentDatabaseChanges, .fetchedDatabaseChanges,
             .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .accountChange:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [self] recordID in
            let name = recordID.recordName
            if let article = articleRecordCache[name] {
                return Self.ckRecord(from: article, zoneID: zoneID)
            }
            if let image = pendingImageUploads[name] {
                return Self.ckRecord(from: image, zoneID: zoneID)
            }
            return nil
        }
    }

    // MARK: Serialization

    private func savedState() -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        return try? CKSyncEngine.State.Serialization(data)
    }

    private static func ckRecord(from a: SyncedArticleRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: articleRecordType, recordID: CKRecord.ID(recordName: a.uid, zoneID: zoneID))
        record["feedIdentifier"] = a.feedIdentifier as CKRecordValue
        record["aggregatorType"] = a.aggregatorType as CKRecordValue
        record["articleIdentifier"] = a.articleIdentifier as CKRecordValue
        record["title"] = a.title as CKRecordValue
        record["url"] = a.url as CKRecordValue
        record["author"] = a.author as CKRecordValue
        record["summary"] = a.summary as CKRecordValue
        record["plainText"] = a.plainText as CKRecordValue
        record["leadImageRef"] = a.leadImageRef as CKRecordValue
        record["iconURL"] = a.iconURL as CKRecordValue?
        record["date"] = a.date as CKRecordValue
        record["createdAt"] = a.createdAt as CKRecordValue
        record["blockData"] = a.blockData as CKRecordValue
        record["isStarred"] = (a.isStarred ? 1 : 0) as CKRecordValue
        record["tagNames"] = a.tagNames as CKRecordValue
        record["imageHashes"] = a.imageHashes as CKRecordValue
        return record
    }

    private static func articleRecord(from record: CKRecord) -> SyncedArticleRecord? {
        guard let feedIdentifier = record["feedIdentifier"] as? String,
              let aggregatorType = record["aggregatorType"] as? String,
              let articleIdentifier = record["articleIdentifier"] as? String,
              let date = record["date"] as? Date,
              let createdAt = record["createdAt"] as? Date else { return nil }
        return SyncedArticleRecord(
            uid: record.recordID.recordName,
            feedIdentifier: feedIdentifier, aggregatorType: aggregatorType, articleIdentifier: articleIdentifier,
            title: record["title"] as? String ?? "", url: record["url"] as? String ?? "",
            author: record["author"] as? String ?? "", summary: record["summary"] as? String ?? "",
            plainText: record["plainText"] as? String ?? "", leadImageRef: record["leadImageRef"] as? String ?? "",
            iconURL: record["iconURL"] as? String, date: date, createdAt: createdAt,
            blockData: record["blockData"] as? Data ?? Data(),
            isStarred: (record["isStarred"] as? Int ?? 0) == 1,
            tagNames: record["tagNames"] as? [String] ?? [],
            imageHashes: record["imageHashes"] as? [String] ?? [])
    }

    private static func ckRecord(from image: SyncedImageRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: imageRecordType, recordID: CKRecord.ID(recordName: image.hash, zoneID: zoneID))
        record["ext"] = image.ext as CKRecordValue
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(image.hash).\(image.ext)")
        try? image.data.write(to: tmp)
        record["blob"] = CKAsset(fileURL: tmp)
        return record
    }

    private static func imageRecord(from record: CKRecord) -> SyncedImageRecord? {
        guard let asset = record["blob"] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return SyncedImageRecord(hash: record.recordID.recordName, ext: record["ext"] as? String ?? "img", data: data)
    }
}
```

> This uses the `CKSyncEngine` API shape (delegate + `nextRecordZoneChangeBatch` + `state.add(pendingRecordZoneChanges:)`). If the exact enum case names differ on the SDK you build against, use context7/Apple docs to reconcile — the `ArticleZoneStore` contract and its fake are the source of truth for behavior; only the CloudKit plumbing here may need name tweaks to compile.

- [ ] **Step 2: Verify it compiles**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Fix any `CKSyncEngine` API name mismatches here (this is the only place they can occur).

- [ ] **Step 3: Wire launch + remote push in `YanaApp.swift`**

In the scene `.task` (after `await ConfigSyncService.shared.start()`), add:

```swift
                    await ArticleSyncService.shared.pull()
```

In `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, after the config pull, add an article pull so a silent push refreshes both:

```swift
        Task { @MainActor in
            await ConfigSyncService.shared.pull()
            await ArticleSyncService.shared.pull()
            completionHandler(.newData)
        }
```

- [ ] **Step 4: Replace the position toggle with the passive toggle in Settings**

In `Yana/Views/Config/SettingsScreenView.swift`, inside `iCloudSyncSection`, replace the `syncTimelinePositionEnabled` `Toggle` block with:

```swift
            if settings.iCloudSyncEnabled {
                Toggle(isOn: Binding(
                    get: { settings.isPassiveDevice },
                    set: { settings.isPassiveDevice = $0 }
                )) {
                    Label(String(localized: "Passive Device"), systemImage: "icloud.and.arrow.down")
                        .labelStyle(.tintedIcon(.blue))
                }
            }
```

Also: on the main `Sync via iCloud` toggle's enable branch, add an article full-push + pull after the config start so a newly enabled device seeds and hydrates:

```swift
                    if newValue {
                        Task {
                            await ConfigSyncService.shared.start()
                            await ConfigSyncService.shared.push()
                            await ArticleSyncService.shared.pull()
                            if !settings.isPassiveDevice { await ArticleSyncService.shared.pushAll() }
                        }
                    } else {
                        ConfigSyncService.shared.stop()
                    }
```

Update the footer copy: replace the "Article contents are not synced…" line and the position line with:

```swift
                Text("Syncs feeds, tags, settings, API keys, and full articles (including images) across your devices via iCloud.")
                if settings.iCloudSyncEnabled {
                    Text("A passive device never fetches in the background and relies on iCloud for its articles.")
                }
```

- [ ] **Step 5: Add the new strings to the string catalog**

Edit `Yana/Resources/Localizable.xcstrings` — add entries with German translations (`"state" : "translated"`):
- `"Passive Device"` → de: `"Passives Gerät"`
- `"Syncs feeds, tags, settings, API keys, and full articles (including images) across your devices via iCloud."` → de: `"Synchronisiert Feeds, Tags, Einstellungen, API-Schlüssel und vollständige Artikel (inklusive Bilder) über iCloud auf allen Geräten."`
- `"A passive device never fetches in the background and relies on iCloud for its articles."` → de: `"Ein passives Gerät ruft nichts im Hintergrund ab und bezieht seine Artikel aus iCloud."`

Remove the now-unused `"Sync Timeline Position"` and its old-position footer string entry (and their translations) if nothing else references them (`grep -rn "Sync Timeline Position" Yana`).

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Wire CKSyncEngine article store, launch pull, and passive-device Settings toggle"
```

---

## Task 10: Docs + full-suite verification + manual two-device check

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites PASS. (Per the memory note, a "Mach error -308" or a runner-launch flake is not a real failure — shut down simulators with `xcrun simctl shutdown all` and retry.)

- [ ] **Step 2: Update CLAUDE.md**

In the `Services` bullet, update the iCloud description to note that **article bodies and images now sync** via `ArticleSyncService` (CKSyncEngine, `Articles` zone, `SyncedArticle`/`SyncedImage` records; UID = `feedIdentifier|aggregatorType|articleIdentifier` with a `date+title` hash fallback), that starred rides on article records (config `starredData` retired), timeline position syncs as the exact anchor identifier, and the passive-device toggle (no background aggregation, no retention). Update the "Article bodies never sync" and "iCloud config sync" descriptions in **Architecture › Services** and the **Enhanced › iCloud config sync** bullet accordingly. Note the SwiftData store is still local-only.

- [ ] **Step 3: Commit docs**

```bash
git add CLAUDE.md
git commit -m "Document iCloud article sync in CLAUDE.md"
```

- [ ] **Step 4: Manual two-device verification (record results)**

On two simulators/devices signed into the same iCloud account, both with sync on:
1. Aggregate on device A → the same articles appear on device B (identical set + order), bodies and images intact.
2. Set device B passive → B stops background-refreshing; new articles from A still arrive on B.
3. Star an article on A → it shows starred on B.
4. Let retention age out an article on A → it disappears on B (tombstone).
5. Read to a position on A → B opens to the same article.

Record pass/fail for each. This is the acceptance gate; unit tests cover the logic, this confirms the CloudKit wiring.

---

## Self-review

**Spec coverage:**
- Real article sync (bodies + images): Tasks 1–4, 9. ✅
- UID with dedup + fallback: Task 1; dedup layers across Tasks 2 (mapping upsert), 3 (pull), 4 (push write-once + image hash), 5 (pre-insert). ✅
- Simplify timeline position → exact UID: Task 8. ✅
- Normal sync ignores already-aggregated: Task 3 (pull dedup) + Task 5 (pull-before-run). ✅
- Re-check before insert if synced meanwhile: Task 5 (pull-before-run + canonical-createdAt adoption). ✅
- Passive-device toggle (no background aggregation, relies on iCloud), manual fetch still works: Task 7 (background gated) + Task 6 (retention skipped); manual paths untouched. ✅
- CKSyncEngine transport (Approach A): Task 9. ✅
- Retention deletion propagation; passive never retends: Task 6. ✅
- Conflict rules (createdAt FWW, rest LWW): Tasks 2 + 5. ✅
- Starred rides on articles; retire starredData: Task 8. ✅
- Migration full-push on enable; passive hydrate: Task 9. ✅
- Localization: Task 9. ✅

**Placeholder scan:** No TBD/TODO; every code step shows full code. The one deliberately deferred piece — exact `CKSyncEngine` enum names — is called out with a reconciliation instruction, not left blank.

**Type consistency:** `SyncedArticleRecord`/`SyncedImageRecord`/`ArticleZoneChanges` fields are identical across Tasks 1–9. `ArticleZoneStore` method names (`fetchChanges`, `upsert(articles:images:)`, `delete(articleUIDs:)`, `fetchImage(hash:)`) match between protocol (Task 3), fake (Task 3), production (Task 9), and service call sites (Tasks 3–6). `ArticleUID.make`, `ArticleRecordApply.feedKey`, `canonicalCreatedAt(forUID:)`, `RetentionCleanup.run → [String]`, and `AppSettings.isPassiveDevice`/`timelineAnchorUID` are used consistently. Ordering note: Task 6's `cleanupAndSave` references `isPassiveDevice` from Task 7 — implement Task 7 before building Task 6 (called out inline).
