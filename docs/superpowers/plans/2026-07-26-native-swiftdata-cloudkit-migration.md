# Native SwiftData + CloudKit Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-built CloudKit sync stack with always-on native SwiftData+CloudKit mirroring, add a per-device update-interval setting (including "no update"), and migrate existing users one time.

**Architecture:** Flip the production `ModelConfiguration` to `cloudKitDatabase: .automatic` so SwiftData mirrors `Feed`/`Tag`/`Article` plus a new `StoredImage` model. Settings sync moves to `NSUbiquitousKeyValueStore`; API keys become unconditionally iCloud-Keychain-synchronizable. A per-device `UpdateInterval` enum replaces the synced `backgroundInterval` and the passive-device flag. App-level `LibraryDedup` handles the duplicate-row problem CloudKit can't prevent. A one-time migration seeds image blobs into SwiftData, remaps settings, and deletes the old CloudKit zones/records.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`@Model`, `@ModelActor`), CloudKit (`NSPersistentCloudKitContainer` via SwiftData mirroring), `NSUbiquitousKeyValueStore`, Swift Testing (`import Testing`) + XCTest.

## Global Constraints

- **Platform:** iOS 26.0+ (iPhone + iPad) and Mac Catalyst. Every test target keeps `SUPPORTS_MACCATALYST`.
- **Concurrency:** Swift 6 strict concurrency; `@MainActor` where the existing code is; background writes via `@ModelActor`.
- **CloudKit model invariants (must hold for ALL synced `@Model` types, forever):** every attribute optional or has a default; every relationship optional with an inverse; **no `#Unique`/`@Attribute(.unique)`**. `#Index` and `.cascade` delete rules are allowed.
- **Container:** `iCloud.de.fa-krug.Yana`, private database. Entitlements already present (CloudKit, container id, `aps-environment`, `remote-notification` background mode) — no entitlement edits.
- **Localization:** every new/changed user-facing string gets a `de` translation in `Yana/Resources/Localizable.xcstrings`, `"state":"translated"`, Apple infinitive style.
- **Test isolation:** production store becomes `.automatic`; the DEBUG screenshot/UITest temp stores stay `cloudKitDatabase: .none`. Any settings-sync (KVS) code is gated OFF under `-UITEST_SCREENSHOTS` / `-UITEST_RESET_LIBRARY` / `MacScreenshotWindow.isRequested` so a capture never reads the developer's real synced prefs.
- **Build/test commands:**
  - `xcodegen generate` after adding/removing any file.
  - Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
  - Test: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- **Commit** after every task (frequent commits).

---

## File Structure

**Create:**
- `Yana/Models/StoredImage.swift` — synced image-blob model (Task 1).
- `Yana/Services/ImageSync.swift` — bridges `ImageStore` (disk) ↔ `StoredImage` (SwiftData) (Task 2).
- `Yana/Models/UpdateInterval.swift` — the interval enum + mapping (Task 4).
- `Yana/Services/SettingsCloudSync.swift` — `NSUbiquitousKeyValueStore` prefs sync (Task 9).
- `Yana/Services/LibraryDedup.swift` — dedup `@ModelActor` + coordinator (Task 11).
- `Yana/Services/NativeCloudKitMigration.swift` — one-time migration (Task 13).
- `Yana/Services/LegacyCloudKitCleanup.swift` — delete old zones/records (Task 14).
- Test files under `YanaTests/` per task.

**Modify:** `Yana/Aggregators/Utils/ImageStore.swift`, `Yana/Reader/ReaderImageCache.swift`, `Yana/Views/Config/FeedLogoView.swift`, `Yana/Models/AppSettings.swift`, `Yana/Services/BackgroundRefreshManager.swift`, `Yana/Services/AggregationWriter.swift`, `Yana/Services/AggregationService.swift`, `Yana/Services/KeychainService.swift`, `Yana/Views/Config/Settings/LibrarySettingsSection.swift`, `Yana/Views/Config/SettingsScreenView.swift`, `Yana/Reader/Mac/MacSettingsWindow.swift`, `Yana/YanaApp.swift`, `Yana/Resources/Localizable.xcstrings`, `CLAUDE.md`.

**Delete:** `Yana/Services/ArticleSync/` (all 6 files), `Yana/Services/ConfigSyncService.swift`, `Yana/Views/Config/Settings/ICloudSyncSettingsSection.swift`.

**Keep (do NOT delete — used app-wide):** `ArticleUID` (`Yana/Aggregators/ArticleUpsert.swift`… wherever `ArticleUID` is defined — timeline anchor, upsert, retention all use it), `StarredRegistry` (preserves starred across a device-local re-fetch).

---

### Task 1: `StoredImage` model

**Files:**
- Create: `Yana/Models/StoredImage.swift`
- Modify: `Yana/YanaApp.swift:45-51` (add `StoredImage.self` to both `ModelContainer(for:)` calls)
- Test: `YanaTests/StoredImageTests.swift`

**Interfaces:**
- Produces: `StoredImage` `@Model` with `var hash: String`, `@Attribute(.externalStorage) var data: Data`, `var ext: String`, `var createdAt: Date`; init `StoredImage(hash:data:ext:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import Yana

@MainActor
struct StoredImageTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func insertsAndFetchesByHash() throws {
        let c = try container()
        c.mainContext.insert(StoredImage(hash: "abc", data: Data([1,2,3]), ext: "jpg"))
        try c.mainContext.save()
        let rows = try c.mainContext.fetch(FetchDescriptor<StoredImage>(
            predicate: #Predicate { $0.hash == "abc" }))
        #expect(rows.count == 1)
        #expect(rows.first?.data == Data([1,2,3]))
        #expect(rows.first?.ext == "jpg")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/StoredImageTests`
Expected: FAIL — `StoredImage` unknown.

- [ ] **Step 3: Create the model**

```swift
// Yana/Models/StoredImage.swift
import Foundation
import SwiftData

/// Content-addressed image blob, synced via SwiftData+CloudKit. The bytes travel as a CKAsset
/// (external storage). `ImageStore` keeps a disk cache in front of this; `ImageSync` bridges the two.
/// `hash` matches the `yana-img://<hash>` refs embedded in article blocks and `Feed.logoHash`.
@Model
final class StoredImage {
    var hash: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
    /// File extension recorded so a materialized cache file gets the right name (e.g. "jpg", "png").
    var ext: String = "img"
    var createdAt: Date = Date.now

    init(hash: String, data: Data, ext: String) {
        self.hash = hash
        self.data = data
        self.ext = ext
        self.createdAt = .now
    }
}
```

- [ ] **Step 4: Register in the container**

In `Yana/YanaApp.swift`, add `StoredImage.self` to BOTH `ModelContainer(for: Feed.self, Tag.self, Article.self, ...)` calls (the DEBUG screenshot store at ~line 45 and the production store at ~line 50):

```swift
return try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                         configurations: config)
```

- [ ] **Step 5: `xcodegen generate`, run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/StoredImageTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/StoredImage.swift Yana/YanaApp.swift YanaTests/StoredImageTests.swift project.yml
git commit -m "Add StoredImage model for synced image blobs"
```

---

### Task 2: `ImageSync` — disk ↔ SwiftData bridge

**Files:**
- Create: `Yana/Services/ImageSync.swift`
- Modify: `Yana/Aggregators/Utils/ImageStore.swift` (add `allHashes()` and `store(data:ext:hash:)`-by-known-hash helper — see below)
- Test: `YanaTests/ImageSyncTests.swift`

**Interfaces:**
- Consumes: `ImageStore.rawData(forHash:)`, `ImageStore.recordedExt(forHash:)`, `ImageStore.fileExists(forHash:)`, `ImageStore.storeData(_:ext:)`, `StoredImage`.
- Produces:
  - `ImageStore.allHashes() -> Set<String>` (actor-isolated).
  - `enum ImageSync` with:
    - `static func ensureStored(hashes: Set<String>, context: ModelContext, imageStore: ImageStore) async` — for each hash with disk bytes and no existing `StoredImage`, insert one.
    - `static func materialize(hash: String, context: ModelContext, imageStore: ImageStore) async -> Bool` — if the disk file is missing but a `StoredImage` exists, write its bytes to the disk cache; returns whether bytes are now on disk.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
struct ImageSyncTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgsync-\(UUID().uuidString)")
        return ImageStore(directory: dir)
    }

    @Test func ensureStoredInsertsRowsForDiskBlobs() async throws {
        let c = try container()
        let store = tempStore()
        let hash = await store.storeData(Data([9,9,9]), ext: "png")
        await ImageSync.ensureStored(hashes: [hash], context: c.mainContext, imageStore: store)
        let rows = try c.mainContext.fetch(FetchDescriptor<StoredImage>())
        #expect(rows.count == 1)
        #expect(rows.first?.hash == hash)
        #expect(rows.first?.ext == "png")
    }

    @Test func ensureStoredIsIdempotent() async throws {
        let c = try container()
        let store = tempStore()
        let hash = await store.storeData(Data([1]), ext: "jpg")
        await ImageSync.ensureStored(hashes: [hash], context: c.mainContext, imageStore: store)
        await ImageSync.ensureStored(hashes: [hash], context: c.mainContext, imageStore: store)
        #expect(try c.mainContext.fetch(FetchDescriptor<StoredImage>()).count == 1)
    }

    @Test func materializeWritesMissingFileFromStoredImage() async throws {
        let c = try container()
        let store = tempStore()
        c.mainContext.insert(StoredImage(hash: "deadbeef", data: Data([7,7]), ext: "jpg"))
        try c.mainContext.save()
        let existedBefore = await store.fileExists(forHash: "deadbeef")
        #expect(existedBefore == false)
        let ok = await ImageSync.materialize(hash: "deadbeef", context: c.mainContext, imageStore: store)
        #expect(ok == true)
        #expect(await store.fileExists(forHash: "deadbeef") == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageSyncTests`
Expected: FAIL — `ImageSync`/`allHashes` unknown.

- [ ] **Step 3: Add `ImageStore.allHashes()`**

In `Yana/Aggregators/Utils/ImageStore.swift`, add inside the actor (after `recordedExt`):

```swift
/// Every content hash currently cached on disk (from the seeded extension map).
func allHashes() -> Set<String> { Set(extensions.keys) }
```

- [ ] **Step 4: Create `ImageSync`**

```swift
// Yana/Services/ImageSync.swift
import Foundation
import SwiftData

/// Bridges the on-disk `ImageStore` cache and the synced `StoredImage` SwiftData rows.
/// `ImageStore` stays the fast path for the reader; `StoredImage` is the synced source of truth.
enum ImageSync {
    /// Insert a `StoredImage` for each hash that has bytes on disk but no row yet. Called from the
    /// aggregation write path (after upserts) so every image an article references gets mirrored.
    @MainActor
    static func ensureStored(hashes: Set<String>, context: ModelContext, imageStore: ImageStore) async {
        guard !hashes.isEmpty else { return }
        let existing = Set((try? context.fetch(FetchDescriptor<StoredImage>()))?.map(\.hash) ?? [])
        var inserted = false
        for hash in hashes where !existing.contains(hash) {
            guard let bytes = await imageStore.rawData(forHash: hash) else { continue }
            let ext = await imageStore.recordedExt(forHash: hash)
            context.insert(StoredImage(hash: hash, data: bytes, ext: ext))
            inserted = true
        }
        if inserted { try? context.save() }
    }

    /// Ensure the disk cache has bytes for `hash`. If the file is missing but a synced `StoredImage`
    /// exists (arrived from another device), write the blob to the cache. Returns whether bytes are
    /// on disk afterwards.
    @MainActor
    static func materialize(hash: String, context: ModelContext, imageStore: ImageStore) async -> Bool {
        if await imageStore.fileExists(forHash: hash) { return true }
        let descriptor = FetchDescriptor<StoredImage>(predicate: #Predicate { $0.hash == hash })
        guard let stored = (try? context.fetch(descriptor))?.first else { return false }
        _ = await imageStore.storeData(stored.data, ext: stored.ext)
        return true
    }
}
```

- [ ] **Step 5: `xcodegen generate`, run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageSyncTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/ImageSync.swift Yana/Aggregators/Utils/ImageStore.swift YanaTests/ImageSyncTests.swift project.yml
git commit -m "Add ImageSync bridge between ImageStore and StoredImage"
```

---

### Task 3: Wire `ImageSync` into the aggregation write path + reader/logo fallback

**Files:**
- Modify: `Yana/Services/AggregationService.swift` (after a run, ensure `StoredImage` rows exist for referenced hashes)
- Modify: `Yana/Reader/ReaderImageCache.swift:87-90` (materialize on disk miss)
- Modify: `Yana/Views/Config/FeedLogoView.swift:9` (materialize on disk miss)
- Test: covered by `ImageSyncTests` (unit) + manual sync verification later; add `YanaTests/ImageSyncWirasingTests.swift` only if a pure seam exists. Otherwise this task is integration wiring — verify by build.

**Interfaces:**
- Consumes: `ImageSync.ensureStored`, `ImageSync.materialize`, existing `ArticleStore`/context.

- [ ] **Step 1: Ensure rows after a run.** In `AggregationService`, add a helper that collects the hashes referenced by all articles + feed logos and calls `ImageSync.ensureStored`. Call it at the end of `updateAll()`, `update(feed:)`, `forceReload(feed:)`, `forceReload(article:)` (after `refreshFromStore()`/`reconcileArticle`). Collect hashes from `article.leadImageRef`, any `yana-img://` refs in `article.blocks`, and `feed.logoHash`:

```swift
/// Register StoredImage rows for every image the current library references, so CloudKit mirrors
/// the blobs. Cheap: ensureStored skips hashes that already have a row.
private func syncReferencedImages() async {
    let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
    let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
    var hashes = Set<String>()
    for feed in feeds { if let h = feed.logoHash, !h.isEmpty { hashes.insert(h) } }
    for article in articles {
        if !article.leadImageRef.isEmpty { hashes.insert(Self.hash(fromRef: article.leadImageRef)) }
        for block in article.blocks {
            if case let .image(ref, _) = block { hashes.insert(Self.hash(fromRef: ref)) }
        }
    }
    hashes.remove("")
    await ImageSync.ensureStored(hashes: hashes, context: context, imageStore: .shared)
}

/// Strip the `yana-img://` scheme prefix to get the bare content hash.
private static func hash(fromRef ref: String) -> String {
    let prefix = "\(ReaderWeb.imageScheme)://"
    return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
}
```

Note: `Block.image` associated values are `(ref, alt)` per `Article.blocks` setter (`case let .image(ref, _)`). Match that shape.

- [ ] **Step 2: Reader materialize-on-miss.** In `ReaderImageCache.swift`, where it resolves `let url = await ImageStore.shared.fileURL(forHash: hash)` (line ~90), first ensure the file exists by materializing from `StoredImage`:

```swift
_ = await ImageSync.materialize(hash: hash, context: AppContainer.shared.mainContext, imageStore: .shared)
let url = await ImageStore.shared.fileURL(forHash: hash)
```

- [ ] **Step 3: Feed logo materialize-on-miss.** In `FeedLogoView.swift` (line ~9), before `let url = await store.fileURL(forHash: hash)`:

```swift
_ = await ImageSync.materialize(hash: hash, context: AppContainer.shared.mainContext, imageStore: store)
let url = await store.fileURL(forHash: hash)
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. (Confirm `ReaderWeb.imageScheme` and `Block.image` case are in scope in `AggregationService`; add `import` if needed — both are in the `Yana` module.)

- [ ] **Step 5: Run full unit suite to confirm no regressions**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageSyncTests -only-testing:YanaTests/StoredImageTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AggregationService.swift Yana/Reader/ReaderImageCache.swift Yana/Views/Config/FeedLogoView.swift
git commit -m "Register StoredImage rows on aggregation; materialize images on cache miss"
```

---

### Task 4: `UpdateInterval` enum + `AppSettings.updateInterval`

**Files:**
- Create: `Yana/Models/UpdateInterval.swift`
- Modify: `Yana/Models/AppSettings.swift` (add `updateInterval` property + Key; keep `backgroundInterval` property for migration mapping only)
- Test: `YanaTests/UpdateIntervalTests.swift`

**Interfaces:**
- Produces:
  - `enum UpdateInterval: String, CaseIterable, Identifiable, Sendable { case off, min30, min60, hour2, hour4, hour8, hour24 }` with `var seconds: TimeInterval?` (nil for `.off`), `var id: String`, `var localizedLabel: String`, and `static func nearest(toSeconds:) -> UpdateInterval`.
  - `AppSettings.updateInterval: UpdateInterval` (device-local, UserDefaults key `"settings.updateInterval"`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct UpdateIntervalTests {
    @Test func secondsMapping() {
        #expect(UpdateInterval.off.seconds == nil)
        #expect(UpdateInterval.min30.seconds == 1800)
        #expect(UpdateInterval.min60.seconds == 3600)
        #expect(UpdateInterval.hour24.seconds == 86400)
    }

    @Test func nearestFromLegacySeconds() {
        #expect(UpdateInterval.nearest(toSeconds: 3600) == .min60)
        #expect(UpdateInterval.nearest(toSeconds: 300)  == .min30)   // 5 min → closest non-off
        #expect(UpdateInterval.nearest(toSeconds: 21600) == .hour8)   // 6h → 8h nearest of the set
        #expect(UpdateInterval.nearest(toSeconds: 0) == .min30)       // never maps to .off
    }

    @Test func settingsRoundTrip() {
        let d = UserDefaults(suiteName: "updateinterval-test")!
        d.removePersistentDomain(forName: "updateinterval-test")
        let s = AppSettings(defaults: d)
        #expect(s.updateInterval == .min60)   // default
        s.updateInterval = .off
        #expect(AppSettings(defaults: d).updateInterval == .off)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UpdateIntervalTests`
Expected: FAIL — `UpdateInterval` unknown.

- [ ] **Step 3: Create the enum**

```swift
// Yana/Models/UpdateInterval.swift
import Foundation

/// How often THIS device aggregates in the background. Device-local, never synced (each device
/// picks its own cadence). `.off` makes the device a pure iCloud mirror: no background aggregation
/// and no retention cleanup — it still receives synced articles/deletes via CloudKit.
enum UpdateInterval: String, CaseIterable, Identifiable, Sendable {
    case off, min30, min60, hour2, hour4, hour8, hour24

    var id: String { rawValue }

    /// Interval in seconds, or nil for `.off`.
    var seconds: TimeInterval? {
        switch self {
        case .off:    return nil
        case .min30:  return 1800
        case .min60:  return 3600
        case .hour2:  return 7200
        case .hour4:  return 14400
        case .hour8:  return 28800
        case .hour24: return 86400
        }
    }

    var localizedLabel: String {
        switch self {
        case .off:    return String(localized: "No updates")
        case .min30:  return String(localized: "Every 30 minutes")
        case .min60:  return String(localized: "Every hour")
        case .hour2:  return String(localized: "Every 2 hours")
        case .hour4:  return String(localized: "Every 4 hours")
        case .hour8:  return String(localized: "Every 8 hours")
        case .hour24: return String(localized: "Every 24 hours")
        }
    }

    /// Map a legacy `backgroundInterval` (seconds) to the nearest non-`.off` case (a positive legacy
    /// value always meant "refresh", so it never collapses to `.off`).
    static func nearest(toSeconds seconds: TimeInterval) -> UpdateInterval {
        let candidates: [UpdateInterval] = [.min30, .min60, .hour2, .hour4, .hour8, .hour24]
        let target = seconds > 0 ? seconds : 1800
        return candidates.min(by: { abs(($0.seconds ?? 0) - target) < abs(($1.seconds ?? 0) - target) }) ?? .min60
    }
}
```

- [ ] **Step 4: Add `updateInterval` to `AppSettings`**

In `Yana/Models/AppSettings.swift`, add a Key and property (place near the iCloud/device-local section). Register a default:

In `init`'s `register(defaults:)` dict add: `Key.updateInterval: UpdateInterval.min60.rawValue,`

Add to `enum Key`: `static let updateInterval = "settings.updateInterval"`

Add the property:

```swift
/// Per-device background aggregation cadence. Device-local — never synced. `.off` = pure mirror.
var updateInterval: UpdateInterval {
    get {
        access(keyPath: \.updateInterval)
        guard let raw = defaults.string(forKey: Key.updateInterval),
              let value = UpdateInterval(rawValue: raw) else { return .min60 }
        return value
    }
    set { withMutation(keyPath: \.updateInterval) { defaults.set(newValue.rawValue, forKey: Key.updateInterval) } }
}
```

Leave `backgroundInterval` in place for now (the migration reads it in Task 13; it is removed from the synced set in Task 9).

- [ ] **Step 5: `xcodegen generate`, run the test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UpdateIntervalTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/UpdateInterval.swift Yana/Models/AppSettings.swift YanaTests/UpdateIntervalTests.swift project.yml
git commit -m "Add per-device UpdateInterval setting"
```

---

### Task 5: `BackgroundRefreshManager` honors `updateInterval`; `.off` = no scheduling

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift`
- Test: `YanaTests/BackgroundRefreshManagerTests.swift` (extend existing if present; else create)

**Interfaces:**
- Consumes: `AppSettings.updateInterval`.
- Produces: `register()`/`schedule()`/`runNow()`/`scheduleMac()` all no-op when the interval is `.off`; interval seconds come from `updateInterval.seconds`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import Yana

@MainActor
struct BackgroundRefreshIntervalTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func offMeansNoScheduling() throws {
        let c = try container()
        var scheduled = false
        // isDisabled provider returns true → schedule() must early-return before submitting.
        let mgr = BackgroundRefreshManager(
            container: c,
            secondsProvider: { nil },              // .off → nil seconds
            now: { .init(timeIntervalSince1970: 0) },
            onScheduleAttempt: { scheduled = true } // test seam, see Step 3
        )
        mgr.schedule()
        #expect(scheduled == false)
    }

    @Test func nextBeginUsesProvidedSeconds() {
        let begin = BackgroundRefreshManager.nextBeginDate(
            from: .init(timeIntervalSince1970: 0), interval: 3600)
        #expect(begin == .init(timeIntervalSince1970: 3600))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshIntervalTests`
Expected: FAIL — new init params unknown.

- [ ] **Step 3: Rework the manager to a seconds-or-nil provider**

Replace the `intervalProvider`/`isPassive` pair with a single optional-seconds provider (nil = off). Add a small `onScheduleAttempt` test seam.

Change the stored properties and init:

```swift
private let container: ModelContainer
private let secondsProvider: @MainActor () -> TimeInterval?   // nil = .off (no scheduling)
private let now: () -> Date
private let onScheduleAttempt: @MainActor () -> Void          // test seam; default no-op

init(
    container: ModelContainer,
    secondsProvider: @escaping @MainActor () -> TimeInterval? = { AppSettings().updateInterval.seconds },
    now: @escaping () -> Date = { .now },
    onScheduleAttempt: @escaping @MainActor () -> Void = {}
) {
    self.container = container
    self.secondsProvider = secondsProvider
    self.now = now
    self.onScheduleAttempt = onScheduleAttempt
}
```

Replace every `guard !isPassive() else { return }` with `guard secondsProvider() != nil else { return }` in `register()`, `runNow()`, `schedule()`, `scheduleMac()`.

In `schedule()` (non-Mac branch) and `scheduleMac()`, call `onScheduleAttempt()` right after the guard, and compute the interval from the provider:

```swift
func schedule() {
    guard let seconds = secondsProvider() else { return }
    onScheduleAttempt()
    #if targetEnvironment(macCatalyst)
    scheduleMac(seconds: seconds)
    #else
    let begin = Self.nextBeginDate(from: now(), interval: seconds)
    // ... unchanged submit logic using `begin`
    #endif
}
```

Adjust `scheduleMac` to take `seconds: TimeInterval` and drop its own guard/provider read. Keep `nextBeginDate` unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshIntervalTests`
Expected: PASS.

- [ ] **Step 5: Build the whole app (callers of the old init)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (the only caller is `AppDelegate.backgroundRefresh` which uses the default init).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift YanaTests/BackgroundRefreshIntervalTests.swift
git commit -m "BackgroundRefreshManager honors UpdateInterval; .off disables scheduling"
```

---

### Task 6: Retention gating switches to `.off`; drop `articleSync` from `AggregationService`

**Files:**
- Modify: `Yana/Services/AggregationWriter.swift` (rename `isPassiveDevice` field → `skipRetention`)
- Modify: `Yana/Services/AggregationService.swift` (remove `articleSync` dependency and all pull/push/deleteRemote calls; feed the retention flag from `updateInterval == .off`)
- Test: `YanaTests/AggregationRetentionGateTests.swift`

**Interfaces:**
- Consumes: `AppSettings.updateInterval`.
- Produces: `AggregationRunInputs.skipRetention: Bool`; `AggregationService` no longer references `ArticleSyncService`/`StarredRegistry`-via-sync push (StarredRegistry stays for starred re-application — keep that usage).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import Yana

@MainActor
struct AggregationRetentionGateTests {
    @Test func offDeviceSkipsRetentionCleanup() throws {
        let c = try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // Insert an article well past the retention window.
        let old = Article(title: "old", identifier: "o1", url: "u", date: .distantPast)
        old.createdAt = .distantPast
        c.mainContext.insert(old)
        try c.mainContext.save()
        let writer = AggregationWriter(modelContainer: c)
        let inputs = TestInputs.make(skipRetention: true, retentionDays: 1)  // helper mirrors makeRunInputs
        let deleted = writer.testCleanup(inputs)   // expose cleanup for the test (see Step 3)
        #expect(deleted.isEmpty)
    }
}
```

(If a `TestInputs.make`/`testCleanup` seam is heavier than warranted, instead assert the field rename compiles and that `makeRunInputs()` sets `skipRetention` from `updateInterval == .off` via a focused test on `AggregationService`. Choose the lighter seam that still proves the gate.)

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationRetentionGateTests`
Expected: FAIL — `skipRetention` unknown.

- [ ] **Step 3: Rename the run-input field and its use**

In `AggregationWriter.swift`: rename `let isPassiveDevice: Bool` → `let skipRetention: Bool`, and change `cleanup` guard:

```swift
private func cleanup(_ inputs: AggregationRunInputs) -> [String] {
    guard !inputs.skipRetention else { return [] }
    let deleted = RetentionCleanup.run(context: modelContext, retentionDays: inputs.retentionDays, now: inputs.now)
    try? modelContext.save()
    return deleted
}
```

In `AggregationService.makeRunInputs()`: replace `isPassiveDevice: settings.isPassiveDevice,` with `skipRetention: settings.updateInterval == .off,`.

- [ ] **Step 4: Remove the article-sync coupling**

In `AggregationService.swift`:
- Delete the stored property `private let articleSync: ArticleSyncService` and its init parameter/assignment.
- Delete every `await articleSync.pull()`, `await articleSync.push(uids:)`, and the `if !result.deletedUIDs.isEmpty { await articleSync.deleteRemote(...) }` lines in `updateAll()`, `update(feed:)`, `forceReload(feed:)`, `forceReload(article:)`, `summarize(_:)`.
- Keep the `try? context.save()` "flush" lines and `refreshFromStore()`/`reconcileArticle`.
- At the end of `updateAll()`/`update(feed:)`/`forceReload(feed:)`/`forceReload(article:)`, add `await syncReferencedImages()` (from Task 3) if not already present.
- Keep `starredRegistry` (unrelated to sync — it re-applies starred at import).

Note: `AggregationWriter` still computes `touchedUIDs`/`deletedUIDs`; they are now unused by the coordinator but harmless. Leave them (removing them widens the diff into `ArticleUpsert`/`RetentionCleanup` unnecessarily; `deletedUIDs` also still exercises `ArticleUID`).

- [ ] **Step 5: Run the test + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationRetentionGateTests && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: PASS + BUILD SUCCEEDED (note: `YanaApp.swift` still references `ArticleSyncService`/`ConfigSyncService` in the scene `.task` and `didReceiveRemoteNotification` — those are removed in Task 8; if the build breaks only there, proceed to Task 8 before declaring this task green, or temporarily leave those call sites — prefer doing Task 8 immediately next).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AggregationWriter.swift Yana/Services/AggregationService.swift YanaTests/AggregationRetentionGateTests.swift
git commit -m "Gate retention on UpdateInterval.off; drop article-sync coupling from AggregationService"
```

---

### Task 7: Delete the hand-built sync stack + its call sites

**Files:**
- Delete: `Yana/Services/ArticleSync/ArticleSyncService.swift`, `CloudKitArticleZoneStore.swift`, `ArticleZoneStore.swift`, `SyncedArticleRecord.swift`, `ArticleRecordMapping.swift`, `CloudKitSchemaBootstrap.swift`
- Delete: `Yana/Services/ConfigSyncService.swift`
- Modify: `Yana/YanaApp.swift` (remove sync calls in scene `.task`, `didReceiveRemoteNotification`, the DEBUG `CloudKitSchemaBootstrap` task, and `restoreSynchronizableFlag`)
- Test: build + full suite

**Interfaces:** none produced; this removes symbols.

- [ ] **Step 1: Delete the files**

```bash
git rm Yana/Services/ArticleSync/ArticleSyncService.swift \
       Yana/Services/ArticleSync/CloudKitArticleZoneStore.swift \
       Yana/Services/ArticleSync/ArticleZoneStore.swift \
       Yana/Services/ArticleSync/SyncedArticleRecord.swift \
       Yana/Services/ArticleSync/ArticleRecordMapping.swift \
       Yana/Services/ArticleSync/CloudKitSchemaBootstrap.swift \
       Yana/Services/ConfigSyncService.swift
```

- [ ] **Step 2: Remove call sites in `YanaApp.swift`**

- In the DEBUG block of `didFinishLaunchingWithOptions`, delete the `Task(priority: .utility) { await CloudKitSchemaBootstrap().pushIfNeeded() }` block.
- Delete the `KeychainService.restoreSynchronizableFlag(iCloudSyncEnabled: AppSettings().iCloudSyncEnabled)` line (keys become always-synchronizable in Task 8).
- In `didReceiveRemoteNotification`, replace the body with just `completionHandler(.newData)` (native mirroring imports on its own; no manual pull):

```swift
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    // SwiftData+CloudKit mirroring imports remote changes automatically; nothing to pull by hand.
    completionHandler(.newData)
}
```

- In the SwiftUI scene `.task`, delete the two lines `await ConfigSyncService.shared.start()` and `await ArticleSyncService.shared.pull()`. Keep `articleStore.start()` and `BlockMigration.run(...)`.

- [ ] **Step 3: Grep for stragglers**

Run: `grep -rn --include='*.swift' "ArticleSyncService\|ConfigSyncService\|CloudKitSchemaBootstrap\|restoreSynchronizableFlag" Yana YanaTests`
Expected: only matches remaining are in `ICloudSyncSettingsSection.swift` (removed in Task 10) — if Task 10 hasn't run yet, temporarily comment those out or do Task 10 first. Prefer ordering Task 10 immediately after. Fix any test references (delete obsolete sync tests under `YanaTests/`).

- [ ] **Step 4: `xcodegen generate` + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED once Task 10 is also applied (do them together if the only failures are the settings-section references).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Delete hand-built CloudKit sync stack and its call sites"
```

---

### Task 8: API keys always iCloud-Keychain-synchronizable

**Files:**
- Modify: `Yana/Services/KeychainService.swift`
- Test: `YanaTests/KeychainSyncDefaultTests.swift`

**Interfaces:**
- Produces: `KeychainService.synchronizeWithICloud` defaults to `true`; `migrateSynchronizable(to:)` kept (used once by migration); `restoreSynchronizableFlag` removed.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Yana

struct KeychainSyncDefaultTests {
    @Test func defaultsToSynchronizable() {
        #expect(KeychainService.synchronizeWithICloud == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/KeychainSyncDefaultTests`
Expected: FAIL (default is currently `false`).

- [ ] **Step 3: Flip the default and remove `restoreSynchronizableFlag`**

In `KeychainService.swift`:
- Change `nonisolated(unsafe) static var synchronizeWithICloud: Bool = false` → `= true`.
- Delete `restoreSynchronizableFlag(iCloudSyncEnabled:)` (already unreferenced after Task 7).
- Keep `migrateSynchronizable(to:)` — Task 13 calls it once to move existing local-domain keys into the synced domain.

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/KeychainSyncDefaultTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/KeychainService.swift YanaTests/KeychainSyncDefaultTests.swift
git commit -m "Make API keys always iCloud-Keychain-synchronizable"
```

---

### Task 9: Settings sync via `NSUbiquitousKeyValueStore`

**Files:**
- Create: `Yana/Services/SettingsCloudSync.swift`
- Modify: `Yana/Models/AppSettings.swift` (`SyncedSettings`: drop `backgroundInterval`; `exportSyncedSettings` always includes `timelineAnchorUID`; drop the `backgroundInterval` apply)
- Modify: `Yana/YanaApp.swift` (start `SettingsCloudSync` on launch; push on background)
- Test: `YanaTests/SettingsCloudSyncTests.swift`

**Interfaces:**
- Consumes: `AppSettings.exportSyncedSettings()`, `applySyncedSettings(_:)`.
- Produces: `enum SettingsCloudSync` with `static let key = "yana.syncedSettings"`, `static func push(_ settings: AppSettings, store: KeyValueStore = .ubiquitous)`, `static func pull(into: AppSettings, store: KeyValueStore = .ubiquitous)`, `static func start(_ settings: AppSettings)` (registers the external-change observer), and a `KeyValueStore` protocol so tests use an in-memory fake. Gated OFF under UITest/screenshot launch args.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct SettingsCloudSyncTests {
    final class FakeKV: KeyValueStore {
        var data: [String: Data] = [:]
        func data(forKey key: String) -> Data? { data[key] }
        func set(_ value: Data, forKey key: String) { data[key] = value }
        @discardableResult func synchronize() -> Bool { true }
    }

    private func settings(_ suite: String) -> AppSettings {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return AppSettings(defaults: d)
    }

    @Test func pushThenPullRoundTrips() {
        let kv = FakeKV()
        let a = settings("scs-a")
        a.retentionDays = 47
        a.openaiModel = "gpt-4o"
        SettingsCloudSync.push(a, store: kv)
        let b = settings("scs-b")
        SettingsCloudSync.pull(into: b, store: kv)
        #expect(b.retentionDays == 47)
        #expect(b.openaiModel == "gpt-4o")
    }

    @Test func deviceLocalFieldsNotSynced() {
        let kv = FakeKV()
        let a = settings("scs-c")
        a.updateInterval = .off
        SettingsCloudSync.push(a, store: kv)
        let b = settings("scs-d")   // default .min60
        SettingsCloudSync.pull(into: b, store: kv)
        #expect(b.updateInterval == .min60)   // updateInterval is device-local, never in the payload
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SettingsCloudSyncTests`
Expected: FAIL — `SettingsCloudSync`/`KeyValueStore` unknown.

- [ ] **Step 3: Update `AppSettings.SyncedSettings`**

In `AppSettings.swift`:
- Remove `var backgroundInterval: Double?` from `struct SyncedSettings`.
- In `exportSyncedSettings()` remove the `backgroundInterval:` argument, and change the anchor line to always include it: `timelineAnchorUID: timelineAnchorSyncUID`.
- In `applySyncedSettings(_:)` remove the `if let v = decoded.backgroundInterval { backgroundInterval = v }` line.

- [ ] **Step 4: Create `SettingsCloudSync`**

```swift
// Yana/Services/SettingsCloudSync.swift
import Foundation

/// Abstraction over the iCloud key-value store so tests inject an in-memory fake.
protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStore {}

extension KeyValueStore where Self == NSUbiquitousKeyValueStore {
    static var ubiquitous: NSUbiquitousKeyValueStore { .default }
}

/// Syncs the allow-listed non-secret settings across devices via `NSUbiquitousKeyValueStore`.
/// Feeds/tags/articles/images sync natively through SwiftData+CloudKit; this covers only the
/// UserDefaults-backed prefs SwiftData can't carry. Device-local prefs (updateInterval, voice,
/// onboarding, filter state, window layout) are excluded by virtue of not being in `SyncedSettings`.
@MainActor
enum SettingsCloudSync {
    static let key = "yana.syncedSettings"

    /// True when a UI-test/screenshot run must not touch the developer's real synced prefs.
    static var isSuppressed: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITEST_SCREENSHOTS")
            || args.contains("-UITEST_RESET_LIBRARY")
            || args.contains("-UITEST_SKIP_ONBOARDING")
    }

    static func push(_ settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed else { return }
        store.set(settings.exportSyncedSettings(), forKey: key)
        store.synchronize()
    }

    static func pull(into settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed, let data = store.data(forKey: key) else { return }
        settings.applySyncedSettings(data)
    }

    /// Pull once and observe external changes so remote edits apply live. Call at launch.
    static func start(_ settings: AppSettings) {
        guard !isSuppressed else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        pull(into: settings)
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { pull(into: settings) }
        }
    }
}
```

- [ ] **Step 5: Wire launch + background push in `YanaApp.swift`**

In the scene `.task` (after `articleStore.start()`), add `SettingsCloudSync.start(AppSettings())`. Add a `.onChange(of: scenePhase)` on the `WindowGroup`'s root that pushes on background:

```swift
@Environment(\.scenePhase) private var scenePhase
// ...
ContentView(appState: appState)
    .environment(articleStore)
    .onChange(of: scenePhase) { _, phase in
        if phase == .background { SettingsCloudSync.push(AppSettings()) }
    }
    .task { /* existing */ }
```

- [ ] **Step 6: `xcodegen generate`, run the test + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SettingsCloudSyncTests && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: PASS + BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/SettingsCloudSync.swift Yana/Models/AppSettings.swift Yana/YanaApp.swift YanaTests/SettingsCloudSyncTests.swift project.yml
git commit -m "Sync settings via NSUbiquitousKeyValueStore"
```

---

### Task 10: Settings UI — interval picker, remove the iCloud-sync section

**Files:**
- Modify: `Yana/Views/Config/Settings/LibrarySettingsSection.swift` (Stepper → Picker over `UpdateInterval`)
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (remove `ICloudSyncSettingsSection()`)
- Modify: `Yana/Reader/Mac/MacSettingsWindow.swift` (remove `ICloudSyncSettingsSection()` from the `.general` pane)
- Delete: `Yana/Views/Config/Settings/ICloudSyncSettingsSection.swift`
- Modify: `Yana/Resources/Localizable.xcstrings` (new strings + `de`)
- Test: build + `YanaUITests` smoke (manual)

- [ ] **Step 1: Replace the background-interval Stepper with a Picker**

In `LibrarySettingsSection.swift`, replace the second `Stepper` with:

```swift
Picker(selection: $settings.updateInterval) {
    ForEach(UpdateInterval.allCases) { interval in
        Text(interval.localizedLabel).tag(interval)
    }
} label: {
    Label("Background Updates", systemImage: "arrow.clockwise")
        .labelStyle(.tintedIcon(.blue))
        .lineLimit(2)
        .minimumScaleFactor(0.8)
}
```

Add a section footer noting always-on sync:

```swift
} footer: {
    Text("Your library syncs automatically across your devices via iCloud.")
}
```

(Wrap the existing `Section("Library") { ... }` so it has this footer; keep the retention Stepper.)

- [ ] **Step 2: Remove the sync section from both settings screens**

- `SettingsScreenView.swift`: delete the `ICloudSyncSettingsSection()` line (line ~20).
- `MacSettingsWindow.swift`: delete `ICloudSyncSettingsSection()` from the `.general` case (line ~49).

- [ ] **Step 3: Delete the section file**

```bash
git rm Yana/Views/Config/Settings/ICloudSyncSettingsSection.swift
```

- [ ] **Step 4: Add translations**

In `Yana/Resources/Localizable.xcstrings`, add `"translated"` `de` entries for every new string: the 7 `UpdateInterval` labels (`No updates`→`Keine Aktualisierung`, `Every 30 minutes`→`Alle 30 Minuten`, `Every hour`→`Jede Stunde`, `Every 2 hours`→`Alle 2 Stunden`, `Every 4 hours`→`Alle 4 Stunden`, `Every 8 hours`→`Alle 8 Stunden`, `Every 24 hours`→`Alle 24 Stunden`), `Background Updates`→`Hintergrund-Aktualisierung`, and `Your library syncs automatically across your devices via iCloud.`→`Deine Mediathek wird automatisch über iCloud zwischen deinen Geräten synchronisiert.` Remove now-dead strings only if unused elsewhere (`Sync via iCloud`, `Passive Device`, the old iCloud footers) — verify with grep before deleting from the catalog.

- [ ] **Step 5: `xcodegen generate` + build + full test suite**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: BUILD SUCCEEDED; tests pass (verify `grep -rn "ICloudSyncSettingsSection\|ArticleSyncService\|ConfigSyncService" Yana YanaTests` returns nothing).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Replace iCloud toggle with per-device update-interval picker"
```

---

### Task 11: `LibraryDedup` — collapse duplicate Feeds/Tags/Articles

**Files:**
- Create: `Yana/Services/LibraryDedup.swift`
- Modify: `Yana/YanaApp.swift` (run on scene foreground + after migration)
- Test: `YanaTests/LibraryDedupTests.swift`

**Interfaces:**
- Consumes: `ArticleUID.make(for:)` (existing), `Feed`, `Tag`, `Article`.
- Produces: `@ModelActor actor LibraryDeduper { func deduplicate() throws -> Int }` returning the number of rows deleted; `enum LibraryDedup { static func run(container:) }` (fire-and-forget, `.utility`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import Yana

@MainActor
struct LibraryDedupTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func collapsesDuplicateFeedsKeepingEarliest() async throws {
        let c = try container()
        let ctx = c.mainContext
        let older = Feed(name: "A", aggregatorType: .feedContent, identifier: "id1")
        older.createdAt = .init(timeIntervalSince1970: 100)
        let newer = Feed(name: "A", aggregatorType: .feedContent, identifier: "id1")
        newer.createdAt = .init(timeIntervalSince1970: 200)
        ctx.insert(older); ctx.insert(newer)
        // article on the newer duplicate must re-point to the survivor
        let art = Article(title: "t", identifier: "x", url: "u")
        art.feed = newer
        ctx.insert(art)
        try ctx.save()

        let deduper = LibraryDeduper(modelContainer: c)
        let deleted = try await deduper.deduplicate()
        #expect(deleted == 1)
        let feeds = try ctx.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count == 1)
        #expect(feeds.first?.createdAt == .init(timeIntervalSince1970: 100))
        let arts = try ctx.fetch(FetchDescriptor<Article>())
        #expect(arts.first?.feed?.identifier == "id1")
    }

    @Test func collapsesDuplicateArticlesOrsStarred() async throws {
        let c = try container()
        let ctx = c.mainContext
        _ = Tag.ensureBuiltIns(in: ctx)
        let starred = try ctx.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })).first!
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        ctx.insert(feed)
        let a1 = Article(title: "same", identifier: "dup", url: "u"); a1.feed = feed
        a1.syncFeedIdentifier = "f1"; a1.syncAggregatorType = AggregatorType.feedContent.rawValue
        a1.createdAt = .init(timeIntervalSince1970: 10)
        let a2 = Article(title: "same", identifier: "dup", url: "u"); a2.feed = feed
        a2.syncFeedIdentifier = "f1"; a2.syncAggregatorType = AggregatorType.feedContent.rawValue
        a2.createdAt = .init(timeIntervalSince1970: 20)
        a2.tags.append(starred)   // only the loser is starred
        ctx.insert(a1); ctx.insert(a2)
        try ctx.save()

        let deleted = try await LibraryDeduper(modelContainer: c).deduplicate()
        #expect(deleted == 1)
        let arts = try ctx.fetch(FetchDescriptor<Article>())
        #expect(arts.count == 1)
        #expect(arts.first?.createdAt == .init(timeIntervalSince1970: 10))  // earliest survives
        #expect(arts.first?.isStarred == true)                              // starred OR-ed onto survivor
    }

    @Test func noDuplicatesIsNoOp() async throws {
        let c = try container()
        c.mainContext.insert(Feed(name: "A", aggregatorType: .feedContent, identifier: "id1"))
        try c.mainContext.save()
        #expect(try await LibraryDeduper(modelContainer: c).deduplicate() == 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/LibraryDedupTests`
Expected: FAIL — `LibraryDeduper` unknown.

- [ ] **Step 3: Create `LibraryDedup`**

```swift
// Yana/Services/LibraryDedup.swift
import Foundation
import SwiftData

/// Collapses duplicate rows that CloudKit can create (two devices producing the "same" logical
/// object, or two pre-migration libraries merging on first sync). CloudKit forbids unique
/// constraints, so uniqueness is enforced here, by natural key, after merges.
@ModelActor
actor LibraryDeduper {
    /// Returns the number of rows deleted.
    func deduplicate() throws -> Int {
        var deleted = 0
        deleted += try dedupeFeeds()
        deleted += try dedupeTags()
        deleted += try dedupeArticles()
        if deleted > 0 { try modelContext.save() }
        return deleted
    }

    private func dedupeFeeds() throws -> Int {
        let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
        var groups: [String: [Feed]] = [:]
        for feed in feeds { groups["\(feed.aggregatorType)|\(feed.identifier)", default: []].append(feed) }
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                for article in loser.articles { article.feed = survivor }
                for tag in loser.tags where !survivor.tags.contains(where: { $0.id == tag.id }) {
                    survivor.tags.append(tag)
                }
                modelContext.delete(loser)
                deleted += 1
            }
        }
        return deleted
    }

    private func dedupeTags() throws -> Int {
        let tags = try modelContext.fetch(FetchDescriptor<Tag>())
        var groups: [String: [Tag]] = [:]
        for tag in tags { groups[tag.name, default: []].append(tag) }
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                for article in loser.articles where !article.tags.contains(where: { $0.id == survivor.id }) {
                    article.tags.append(survivor)
                }
                for feed in loser.feeds where !feed.tags.contains(where: { $0.id == survivor.id }) {
                    feed.tags.append(survivor)
                }
                modelContext.delete(loser)
                deleted += 1
            }
        }
        return deleted
    }

    private func dedupeArticles() throws -> Int {
        let articles = try modelContext.fetch(FetchDescriptor<Article>())
        var groups: [String: [Article]] = [:]
        for article in articles {
            guard let uid = ArticleUID.make(for: article) else { continue }
            groups[uid, default: []].append(article)
        }
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }   // earliest = first-writer-wins
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                if loser.isStarred {
                    for tag in loser.tags where tag.isBuiltIn
                        && !survivor.tags.contains(where: { $0.id == tag.id }) {
                        survivor.tags.append(tag)
                    }
                }
                modelContext.delete(loser)
                deleted += 1
            }
        }
        return deleted
    }
}

/// Fire-and-forget dedup pass, off the render path.
enum LibraryDedup {
    static func run(container: ModelContainer) {
        Task.detached(priority: .utility) {
            _ = try? await LibraryDeduper(modelContainer: container).deduplicate()
        }
    }
}
```

Note: confirm `ArticleUID.make(for:)` signature and that `Article.id`/`Tag.id`/`Feed.id` (SwiftData `PersistentIdentifier`) compare with `==`. If `ArticleUID.make` needs `syncFeedIdentifier`/`syncAggregatorType`, the test sets them; verify against the real `ArticleUID` definition and adjust the key construction to match how upsert builds it.

- [ ] **Step 4: Run the dedup tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/LibraryDedupTests`
Expected: PASS.

- [ ] **Step 5: Run dedup on foreground**

In `YanaApp.swift` scene `.onChange(of: scenePhase)`, also run dedup when becoming active (coalesced by the `.utility` detached task):

```swift
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .active: LibraryDedup.run(container: AppContainer.shared)
    case .background: SettingsCloudSync.push(AppSettings())
    default: break
    }
}
```

- [ ] **Step 6: Build + commit**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`

```bash
git add Yana/Services/LibraryDedup.swift Yana/YanaApp.swift YanaTests/LibraryDedupTests.swift project.yml
git commit -m "Add LibraryDedup for CloudKit merge duplicates"
```

---

### Task 12: Enable native CloudKit mirroring

**Files:**
- Modify: `Yana/YanaApp.swift` (production `ModelConfiguration` → `.automatic`; DEBUG schema push)
- Test: build + manual two-device verification (documented)

**Interfaces:** none new.

- [ ] **Step 1: Flip the production store to `.automatic`**

In `AppContainer.shared`, change the production config (keep the DEBUG screenshot temp store `.none`):

```swift
// Native CloudKit mirroring: SwiftData mirrors Feed/Tag/Article/StoredImage to the user's private
// CloudKit database automatically, always on. Local-only (no iCloud account) degrades silently.
let config = ModelConfiguration(cloudKitDatabase: .automatic)
return try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                         configurations: config)
```

Update the big comment above it (currently claims the store is "ALWAYS local-only") to describe native mirroring + the model invariants.

- [ ] **Step 2: DEBUG schema push to Development**

Add, in the DEBUG block of `didFinishLaunchingWithOptions` (off the launch path), a schema initialization so the Development CloudKit schema is created from the model:

```swift
#if DEBUG
Task(priority: .utility) {
    // Push the auto-derived CloudKit schema to Development. Native mirroring generates the
    // underlying managed object model, so initializeCloudKitSchema() is valid here (unlike the
    // retired hand-authored CKSyncEngine schema). Guarded to Simulator/dev only.
    try? AppContainer.shared.initializeCloudKitSchemaIfPossible()
}
#endif
```

Provide `initializeCloudKitSchemaIfPossible()` as a tiny extension that reaches the underlying `NSPersistentCloudKitContainer` if SwiftData exposes it; if it does not in this SDK, instead document that schema is created on first real write in Development and delete this step. Verify against the SDK: if `ModelContainer` has no supported hook, DROP Step 2 and rely on first-write schema creation (note it in CLAUDE.md instead). Do not ship a non-compiling call.

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification (document results in the commit message)**

Because real CloudKit can't be unit-tested: run the app on two simulators (or Simulator + Mac Catalyst) signed into the same iCloud dev account. Confirm: a feed added on device A appears on B; an article + its image appear on B; starring on A reflects on B; deleting via retention on A removes on B; a `.off` device still receives A's articles.

- [ ] **Step 5: Commit**

```bash
git add Yana/YanaApp.swift
git commit -m "Enable native SwiftData+CloudKit mirroring"
```

---

### Task 13: One-time migration

**Files:**
- Create: `Yana/Services/NativeCloudKitMigration.swift`
- Modify: `Yana/Models/AppSettings.swift` (add `hasMigratedToNativeCloudKit`; remove `iCloudSyncEnabled`/`isPassiveDevice` properties, but the migration reads their raw UserDefaults keys)
- Modify: `Yana/YanaApp.swift` (kick migration off the launch path, before dedup/settings-sync depend on it)
- Test: `YanaTests/NativeCloudKitMigrationTests.swift`

**Interfaces:**
- Produces: `enum NativeCloudKitMigration { @MainActor static func runIfNeeded(container:, settings:, imageStore:) async }` and `AppSettings.hasMigratedToNativeCloudKit: Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
struct NativeCloudKitMigrationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func settings(_ suite: String) -> (AppSettings, UserDefaults) {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: d), d)
    }
    private func tempStore() -> ImageStore {
        ImageStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString)"))
    }

    @Test func seedsImagesAndMapsInterval() async throws {
        let c = try container()
        let (s, d) = settings("mig-a")
        d.set(3600.0, forKey: "settings.backgroundInterval")
        let store = tempStore()
        let hash = await store.storeData(Data([5,5]), ext: "jpg")

        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: store)

        #expect(try c.mainContext.fetch(FetchDescriptor<StoredImage>()).contains { $0.hash == hash })
        #expect(s.updateInterval == .min60)          // 3600s → .min60
        #expect(s.hasMigratedToNativeCloudKit == true)
    }

    @Test func passiveMapsToOff() async throws {
        let c = try container()
        let (s, d) = settings("mig-b")
        d.set(true, forKey: "settings.isPassiveDevice")
        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: tempStore())
        #expect(s.updateInterval == .off)
    }

    @Test func isIdempotent() async throws {
        let c = try container()
        let (s, _) = settings("mig-c")
        let store = tempStore()
        _ = await store.storeData(Data([1]), ext: "png")
        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: store)
        let countAfterFirst = try c.mainContext.fetch(FetchDescriptor<StoredImage>()).count
        await NativeCloudKitMigration.runIfNeeded(container: c, settings: s, imageStore: store)
        #expect(try c.mainContext.fetch(FetchDescriptor<StoredImage>()).count == countAfterFirst)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/NativeCloudKitMigrationTests`
Expected: FAIL — symbols unknown.

- [ ] **Step 3: Add the migration flag + drop the retired properties**

In `AppSettings.swift`:
- Add Key `static let hasMigratedToNativeCloudKit = "settings.hasMigratedToNativeCloudKit"` and the property:

```swift
/// One-time: whether the native SwiftData+CloudKit migration has run. Device-local.
var hasMigratedToNativeCloudKit: Bool {
    get { access(keyPath: \.hasMigratedToNativeCloudKit); return defaults.bool(forKey: Key.hasMigratedToNativeCloudKit) }
    set { withMutation(keyPath: \.hasMigratedToNativeCloudKit) { defaults.set(newValue, forKey: Key.hasMigratedToNativeCloudKit) } }
}
```

- Delete the `iCloudSyncEnabled` and `isPassiveDevice` properties and their `Key`s (their raw string keys `"settings.iCloudSyncEnabled"` / `"settings.isPassiveDevice"` are read directly by the migration below). Also delete `backgroundInterval` **after** confirming the only remaining reader is the migration — the migration reads the raw key too, so `backgroundInterval` the property can go. Keep the `Key.backgroundInterval` register-default line removed as well.

- [ ] **Step 4: Create the migration**

```swift
// Yana/Services/NativeCloudKitMigration.swift
import Foundation
import SwiftData

/// One-time migration from the hand-built CloudKit stack to native SwiftData+CloudKit mirroring.
/// Idempotent and off the launch path. Steps: seed StoredImage rows from the on-disk cache, force
/// API keys synchronizable, map the old backgroundInterval/passive flag to UpdateInterval, and mirror
/// current synced prefs into the iCloud key-value store. Old CloudKit zones are removed separately
/// (LegacyCloudKitCleanup), on its own retry flag.
@MainActor
enum NativeCloudKitMigration {
    static func runIfNeeded(
        container: ModelContainer,
        settings: AppSettings = AppSettings(),
        imageStore: ImageStore = .shared
    ) async {
        guard !settings.hasMigratedToNativeCloudKit else { return }

        // 1. Seed StoredImage from every blob already cached on disk.
        let hashes = await imageStore.allHashes()
        await ImageSync.ensureStored(hashes: hashes, context: container.mainContext, imageStore: imageStore)

        // 2. Force existing API keys into the synchronizable domain.
        _ = KeychainService.migrateSynchronizable(to: true)

        // 3. Map legacy cadence → UpdateInterval (read raw keys; the properties are gone).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "settings.isPassiveDevice") {
            settings.updateInterval = .off
        } else if defaults.object(forKey: "settings.backgroundInterval") != nil {
            settings.updateInterval = .nearest(toSeconds: defaults.double(forKey: "settings.backgroundInterval"))
        }

        // 4. Mirror current synced prefs into KVS.
        SettingsCloudSync.push(settings)

        settings.hasMigratedToNativeCloudKit = true
    }
}
```

Note: the test injects a custom `AppSettings(defaults:)`, but step 3 reads `UserDefaults.standard`. For testability, read from `settings`'s own defaults. Change step 3 to read the raw keys off the same defaults the `settings` uses — add an internal accessor on `AppSettings` (e.g. `func legacyDouble(_ key: String) -> Double` / `legacyBool`) or pass the `UserDefaults` in. Prefer adding two tiny internal helpers on `AppSettings`:

```swift
func legacyBool(_ key: String) -> Bool { defaults.bool(forKey: key) }
func legacyDouble(_ key: String) -> Double { defaults.double(forKey: key) }
func legacyHas(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
```

and use `settings.legacyBool("settings.isPassiveDevice")` etc. Update the test expectations accordingly (they already set the keys on the injected defaults).

- [ ] **Step 5: Kick migration at launch (before dedup relies on it)**

In `YanaApp.swift` scene `.task`, before `LibraryDedup.run`/`SettingsCloudSync.start`, run migration then dedup:

```swift
.task {
    articleStore.start()
    await NativeCloudKitMigration.runIfNeeded(container: AppContainer.shared)
    BlockMigration.run(container: AppContainer.shared)
    SettingsCloudSync.start(AppSettings())
    LibraryDedup.run(container: AppContainer.shared)   // clears any first-sync duplicates
    // ... existing Mac launch-refresh block
}
```

- [ ] **Step 6: `xcodegen generate`, run the test + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/NativeCloudKitMigrationTests && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: PASS + BUILD SUCCEEDED. Grep confirms `iCloudSyncEnabled`/`isPassiveDevice`/`backgroundInterval` have no remaining readers: `grep -rn --include='*.swift' "iCloudSyncEnabled\|isPassiveDevice\|backgroundInterval" Yana YanaTests`.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/NativeCloudKitMigration.swift Yana/Models/AppSettings.swift Yana/YanaApp.swift YanaTests/NativeCloudKitMigrationTests.swift project.yml
git commit -m "One-time migration to native CloudKit; drop iCloud toggle/passive/backgroundInterval settings"
```

---

### Task 14: Delete old CloudKit zones/records

**Files:**
- Create: `Yana/Services/LegacyCloudKitCleanup.swift`
- Modify: `Yana/Models/AppSettings.swift` (add `hasCleanedLegacyCloudKit` flag)
- Modify: `Yana/YanaApp.swift` (kick cleanup off the launch path, retried until success)
- Test: `YanaTests/LegacyCloudKitCleanupTests.swift` (against a fake DB seam)

**Interfaces:**
- Produces: `protocol LegacyCloudKitDatabase { func deleteRecordZone(name:) async throws; func deleteRecord(name:) async throws }`, `enum LegacyCloudKitCleanup { static func runIfNeeded(settings:, database:) async }`. Deletes zone `"Articles"`, zone `"SchemaBootstrap"`, and record `"config"` (type `ConfigDocument`) in the default zone.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct LegacyCloudKitCleanupTests {
    final class FakeDB: LegacyCloudKitDatabase {
        var deletedZones: [String] = []
        var deletedRecords: [String] = []
        var failFirst = false
        func deleteRecordZone(name: String) async throws {
            if failFirst { failFirst = false; throw NSError(domain: "x", code: 1) }
            deletedZones.append(name)
        }
        func deleteRecord(name: String) async throws { deletedRecords.append(name) }
    }
    private func settings(_ s: String) -> AppSettings {
        let d = UserDefaults(suiteName: s)!; d.removePersistentDomain(forName: s); return AppSettings(defaults: d)
    }

    @Test func deletesZonesAndConfigRecordThenSetsFlag() async throws {
        let db = FakeDB(); let s = settings("cleanup-a")
        await LegacyCloudKitCleanup.runIfNeeded(settings: s, database: db)
        #expect(db.deletedZones.sorted() == ["Articles", "SchemaBootstrap"])
        #expect(db.deletedRecords == ["config"])
        #expect(s.hasCleanedLegacyCloudKit == true)
    }

    @Test func failureLeavesFlagUnsetForRetry() async throws {
        let db = FakeDB(); db.failFirst = true; let s = settings("cleanup-b")
        await LegacyCloudKitCleanup.runIfNeeded(settings: s, database: db)
        #expect(s.hasCleanedLegacyCloudKit == false)   // not marked done → retried next launch
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/LegacyCloudKitCleanupTests`
Expected: FAIL — symbols unknown.

- [ ] **Step 3: Add the flag**

In `AppSettings.swift` add Key `"settings.hasCleanedLegacyCloudKit"` and a `hasCleanedLegacyCloudKit: Bool` property (same shape as `hasMigratedToNativeCloudKit`).

- [ ] **Step 4: Create the cleanup**

```swift
// Yana/Services/LegacyCloudKitCleanup.swift
import Foundation
import CloudKit

/// Deletes the retired hand-built CloudKit artifacts from the user's private database: the custom
/// `Articles` record zone (CKSyncEngine), the throwaway `SchemaBootstrap` zone, and the default-zone
/// `ConfigDocument` record named "config". Best-effort and retried on later launches until it
/// succeeds; never blocks the app.
protocol LegacyCloudKitDatabase: Sendable {
    func deleteRecordZone(name: String) async throws
    func deleteRecord(name: String) async throws
}

struct CloudKitLegacyDatabase: LegacyCloudKitDatabase {
    let database: CKDatabase
    init(containerID: String = "iCloud.de.fa-krug.Yana") {
        database = CKContainer(identifier: containerID).privateCloudDatabase
    }
    func deleteRecordZone(name: String) async throws {
        _ = try await database.deleteRecordZone(withID: CKRecordZone.ID(zoneName: name))
    }
    func deleteRecord(name: String) async throws {
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: name))
    }
}

@MainActor
enum LegacyCloudKitCleanup {
    static func runIfNeeded(
        settings: AppSettings = AppSettings(),
        database: LegacyCloudKitDatabase = CloudKitLegacyDatabase()
    ) async {
        guard !settings.hasCleanedLegacyCloudKit else { return }
        do {
            try await database.deleteRecordZone(name: "Articles")
            try await database.deleteRecordZone(name: "SchemaBootstrap")
            try await database.deleteRecord(name: "config")
            settings.hasCleanedLegacyCloudKit = true
        } catch {
            // Leave the flag unset so the next launch retries. A "zone/record not found" is fine to
            // treat as success on a device that never synced — but to keep this simple and safe,
            // any error just defers to the next launch.
        }
    }
}
```

Note: a device that never used the old sync has no such zones; `deleteRecordZone` for a missing zone succeeds (CloudKit treats it as a no-op) and `deleteRecord` for a missing record throws `.unknownItem`. To avoid永-retrying on those devices, treat `CKError.unknownItem`/`partialFailure` with only-not-found as success. Refine the `catch` to inspect `CKError` and set the flag when the only failures are not-found. Keep the fake-DB test's not-found path in mind; add a test case if you implement the not-found→success refinement.

- [ ] **Step 5: Kick cleanup at launch**

In `YanaApp.swift` scene `.task`, after migration:

```swift
Task(priority: .utility) { await LegacyCloudKitCleanup.runIfNeeded() }
```

- [ ] **Step 6: `xcodegen generate`, run the test + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/LegacyCloudKitCleanupTests && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: PASS + BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/LegacyCloudKitCleanup.swift Yana/Models/AppSettings.swift Yana/YanaApp.swift YanaTests/LegacyCloudKitCleanupTests.swift project.yml
git commit -m "Delete legacy CloudKit zones/records on migration"
```

---

### Task 15: Docs + full-suite green

**Files:**
- Modify: `CLAUDE.md` (rewrite the iCloud-sync architecture paragraph + Planned Features bullet; note CloudKit model invariants and Production schema deploy)
- Test: full suite + full build (iOS + Mac Catalyst compile)

- [ ] **Step 1: Update `CLAUDE.md`**

Replace the long hand-built-sync description in the Services section and the "iCloud sync ✅" Planned-Features bullet with the native design: always-on SwiftData+CloudKit mirroring of `Feed`/`Tag`/`Article`/`StoredImage`; per-device `UpdateInterval` (`.off` = pure mirror, replaces passive mode); settings via `NSUbiquitousKeyValueStore`; API keys always iCloud-Keychain-synchronizable; `LibraryDedup` for merge duplicates; the one-time `NativeCloudKitMigration` + `LegacyCloudKitCleanup`. State the **CloudKit model invariants** (all attributes optional/defaulted, relationships optional with inverses, no `#Unique`) and that the schema **must be deployed to Production before release**. Remove references to `ConfigSyncService`, `ArticleSyncService`, `CKSyncEngine`, `CloudKitSchemaBootstrap`, `StarredRegistry`-as-sync (note StarredRegistry now only re-applies starred on local re-fetch), the passive-device toggle, and the `-PUSH_CLOUDKIT_SCHEMA` workflow.

- [ ] **Step 2: Full build (iOS) + full test suite**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: BUILD SUCCEEDED; all tests pass.

- [ ] **Step 3: Mac Catalyst compile check**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac build`
Expected: BUILD SUCCEEDED (do not attempt to codesign/run from an automation shell — Catalyst run is blocked there).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Document native SwiftData+CloudKit sync"
```

---

## Self-Review

**Spec coverage:**
- §1 container `.automatic` → Task 12. `StoredImage` + external storage → Task 1. `ImageStore` as cache → Tasks 2–3. `LibraryDedup` by natural key, earliest-createdAt survivor, OR starred → Task 11.
- §2 prefs via `NSUbiquitousKeyValueStore` → Task 9. API keys always synchronizable → Task 8.
- §3 per-device `UpdateInterval` (7 cases, `.off` = mirror) → Task 4; scheduling/retention gating → Tasks 5–6; Settings UI → Task 10.
- §4 one-time migration (seed images, keys, interval map, prefs→KVS, flag) → Task 13; delete old CloudKit zones/records with retry → Task 14; delete retired code → Task 7 + Task 10; schema deploy note → Tasks 12/15.

**Corrections vs. the spec (verified against the codebase):** `ArticleUID` and `StarredRegistry` are used app-wide, so they are **kept** (spec said removed) — `ArticleUID` is reused as the dedup key; `StarredRegistry` stays for local starred re-application. `ImageStore` is a context-less actor, so image→SwiftData writes live in the aggregation path (`ImageSync`), not inside `ImageStore`.

**Placeholder scan:** no TBD/TODO; every code step has real code. Two steps carry explicit *verify-against-SDK* instructions with a concrete fallback (Task 12 Step 2 schema push; Task 14 not-found handling) rather than a placeholder.

**Type consistency:** `UpdateInterval.seconds: TimeInterval?` used consistently by `BackgroundRefreshManager.secondsProvider` (Task 5) and `.nearest(toSeconds:)` (Tasks 4/13). `AggregationRunInputs.skipRetention` renamed once (Task 6) and read once. `ImageSync.ensureStored`/`materialize` signatures match across Tasks 2/3/13. `KeyValueStore`/`LegacyCloudKitDatabase` protocols defined where first used.
