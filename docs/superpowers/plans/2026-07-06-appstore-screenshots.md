# App Store Screenshot Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Autogenerate framed, captioned, App-Store-valid screenshots for Yana with a single `fastlane screenshots` command, using an offline curated content fixture.

**Architecture:** A DEBUG-only launch-argument fixture (`-UITEST_SCREENSHOTS`) seeds curated feeds/articles/tags with programmatically-generated gradient lead images (no network, no bundled binaries). A `fastlane snapshot` UITest navigates the reader → article list → search → feeds and snaps each screen across the 6.9″ iPhone and 13″ iPad simulators. `fastlane frameit` then adds device frames + English captions.

**Tech Stack:** SwiftUI/UIKit, SwiftData, XCUITest, fastlane (`snapshot` + `frameit`, installed via Homebrew), `UIGraphicsImageRenderer` for fixture images.

## Global Constraints

- Platform floor: iOS 26.0+; Swift 6 strict concurrency; `@MainActor` where the codebase already annotates.
- App Store target sizes: **6.9″ iPhone = 1320×2868** (sim: `iPhone 17 Pro Max`), **13″ iPad = 2064×2752** (sim: `iPad Pro 13-inch (M5)`). These are the installed simulators — confirm names with `xcrun simctl list devices available` before editing the Snapfile.
- Languages: **English only** (`en-US`).
- All new fixture code (`ScreenshotSeed`, `ScreenshotImageFactory`) is `#if DEBUG` and reachable ONLY via the `-UITEST_SCREENSHOTS` launch argument — it must never touch the normal launch or the `YANA_SEED_ARTICLES` perf path.
- No new user-facing strings are added to the shipping app, so no `Localizable.xcstrings` changes are required. Caption copy lives in fastlane `title.strings`, not the app.
- Images are generated at runtime (Core Graphics) — do NOT bundle image binaries or fetch from the network.
- Regenerate the Xcode project with `xcodegen generate` after any file add/remove before building.
- fastlane is NOT installed and system Ruby is 2.6.10 — install via `brew install fastlane` (bundles its own Ruby); do not use the system Gemfile/bundler path.

---

### Task 1: `ImageStore.storeData` — write local image bytes into the store

The fixture needs to put generated JPEG bytes into `ImageStore` under a `yana-img://<hash>` ref that the reader/cache can resolve. `ImageStore` today only has `store(remoteURL:)` (network fetch) and keeps a private `hash -> ext` map used by `fileURL(forHash:)`. Add a synchronous-data entry point that records the extension so `fileURL(forHash:)` resolves correctly.

**Files:**
- Modify: `Yana/Aggregators/Utils/ImageStore.swift`
- Test: `YanaTests/ImageStoreStoreDataTests.swift`

**Interfaces:**
- Produces: `func storeData(_ data: Data, ext: String) -> String` on `actor ImageStore` — hashes `data` (SHA256), records `ext` in the `extensions` map, writes `<hash>.<ext>` into the store directory if absent, returns the hash. `ext` is a bare extension without a dot (e.g. `"jpg"`).
- Consumes (Task 3): `ImageStore.shared.storeData(jpegData, ext: "jpg")`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct ImageStoreStoreDataTests {
    private func tempStore() -> (ImageStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imagestore-test-\(UUID().uuidString)")
        return (ImageStore(directory: dir), dir)
    }

    @Test func storeDataRoundTrips() async throws {
        let (store, _) = tempStore()
        let bytes = Data([0x01, 0x02, 0x03, 0x04])

        let hash = await store.storeData(bytes, ext: "jpg")

        let url = await store.fileURL(forHash: hash)
        #expect(url.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func storeDataIsContentAddressed() async throws {
        let (store, _) = tempStore()
        let bytes = Data([0xAA, 0xBB])
        let h1 = await store.storeData(bytes, ext: "jpg")
        let h2 = await store.storeData(bytes, ext: "jpg")
        #expect(h1 == h2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaTests/ImageStoreStoreDataTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'ImageStore' has no member 'storeData'`.

- [ ] **Step 3: Add the method**

In `Yana/Aggregators/Utils/ImageStore.swift`, add after `store(remoteURL:...)` (before `fileURL(forHash:)`):

```swift
/// Stores already-decoded local image bytes (no fetch, no recompression) under a
/// content hash, recording `ext` so `fileURL(forHash:)` resolves the right file.
/// Used by DEBUG screenshot/test fixtures; `ext` is a bare extension, e.g. "jpg".
func storeData(_ data: Data, ext: String) -> String {
    let hash = Self.hash(data)
    extensions[hash] = ext
    let url = fileURL(forHash: hash)
    if !FileManager.default.fileExists(atPath: url.path) {
        try? data.write(to: url)
    }
    return hash
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaTests/ImageStoreStoreDataTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Yana/Aggregators/Utils/ImageStore.swift YanaTests/ImageStoreStoreDataTests.swift
git commit -m "Add ImageStore.storeData for local image bytes"
```

---

### Task 2: `ScreenshotImageFactory` — programmatic gradient lead images

Generate attractive, deterministic JPEG lead images at runtime so the fixture has no network dependency and no bundled binaries. Each image is a diagonal gradient between two palette colors with a subtle darkening at the bottom (so overlaid nav text stays legible).

**Files:**
- Create: `Yana/Utilities/ScreenshotImageFactory.swift`
- Test: `YanaTests/ScreenshotImageFactoryTests.swift`

**Interfaces:**
- Produces: `enum ScreenshotImageFactory` with `static func jpeg(index: Int) -> Data` — returns non-empty JPEG data; picks a palette deterministically from `index`. DEBUG-only.
- Consumes (Task 3): `ScreenshotImageFactory.jpeg(index: i)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct ScreenshotImageFactoryTests {
    @Test func producesNonEmptyJPEG() {
        let data = ScreenshotImageFactory.jpeg(index: 0)
        #expect(data.count > 1000)
        // JPEG SOI marker.
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func isDeterministic() {
        #expect(ScreenshotImageFactory.jpeg(index: 3) == ScreenshotImageFactory.jpeg(index: 3))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaTests/ScreenshotImageFactoryTests 2>&1 | tail -20`
Expected: FAIL — cannot find `ScreenshotImageFactory`.

- [ ] **Step 3: Implement the factory**

Create `Yana/Utilities/ScreenshotImageFactory.swift`:

```swift
#if DEBUG
import UIKit

/// Deterministic, network-free lead images for the screenshot fixture (`-UITEST_SCREENSHOTS`).
/// Renders a diagonal two-color gradient with a bottom vignette so the images look like
/// editorial photos without shipping any binary assets.
enum ScreenshotImageFactory {
    /// Palette pairs (top-leading -> bottom-trailing), chosen for a warm, magazine-y feel.
    private static let palettes: [(UIColor, UIColor)] = [
        (UIColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 1), UIColor(red: 0.36, green: 0.55, blue: 0.79, alpha: 1)),
        (UIColor(red: 0.42, green: 0.16, blue: 0.24, alpha: 1), UIColor(red: 0.86, green: 0.44, blue: 0.38, alpha: 1)),
        (UIColor(red: 0.13, green: 0.34, blue: 0.29, alpha: 1), UIColor(red: 0.40, green: 0.70, blue: 0.53, alpha: 1)),
        (UIColor(red: 0.28, green: 0.20, blue: 0.42, alpha: 1), UIColor(red: 0.60, green: 0.48, blue: 0.82, alpha: 1)),
        (UIColor(red: 0.40, green: 0.32, blue: 0.10, alpha: 1), UIColor(red: 0.85, green: 0.68, blue: 0.28, alpha: 1)),
    ]

    static func jpeg(index: Int) -> Data {
        let size = CGSize(width: 1200, height: 800)
        let (a, b) = palettes[abs(index) % palettes.count]
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [a.cgColor, b.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: .zero,
                                      end: CGPoint(x: size.width, y: size.height),
                                      options: [])
            }
            // Bottom vignette for text legibility.
            let vignette = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.35).cgColor] as CFArray
            if let vg = CGGradient(colorsSpace: space, colors: vignette, locations: [0, 1]) {
                cg.drawLinearGradient(vg,
                                      start: CGPoint(x: 0, y: size.height * 0.55),
                                      end: CGPoint(x: 0, y: size.height),
                                      options: [])
            }
        }
        // jpegData never returns nil for a renderer-produced image, but guard defensively.
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaTests/ScreenshotImageFactoryTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Yana/Utilities/ScreenshotImageFactory.swift YanaTests/ScreenshotImageFactoryTests.swift
git commit -m "Add ScreenshotImageFactory for offline fixture lead images"
```

---

### Task 3: `ScreenshotSeed` fixture + launch-argument wiring

Insert a curated, offline library when launched with `-UITEST_SCREENSHOTS`. Mirrors `DebugSeed`'s shape (feed + articles + anchor) but with realistic content spanning aggregator types, colored tags, a lead image per article, and an AI summary on the hero article.

**Files:**
- Create: `Yana/Utilities/ScreenshotSeed.swift`
- Modify: `Yana/YanaApp.swift` (AppDelegate `didFinishLaunchingWithOptions`)
- Test: `YanaTests/ScreenshotSeedTests.swift`

**Interfaces:**
- Consumes: `ImageStore.shared.storeData(_:ext:)` (Task 1), `ScreenshotImageFactory.jpeg(index:)` (Task 2), `BlockParser.blocks(fromHTML:)`, `Article`, `Feed`, `Tag`, `AppSettings.timelineAnchorIdentifier`.
- Produces: `enum ScreenshotSeed` with `@MainActor static func seedIfRequested(into context: ModelContext) async` — no-op unless `ProcessInfo.processInfo.arguments.contains("-UITEST_SCREENSHOTS")`; idempotent (bails if any `Feed` already exists).

First, confirm the exact `Article`, `Feed`, and `Tag` initializers and the `summary`/`leadImageRef` fields by reading `Yana/Models/Article.swift`, `Yana/Models/Feed.swift`, `Yana/Models/Tag.swift`. Task 1's `DebugSeed` shows the shape: `Feed(name:aggregatorType:identifier:)`, `Article(title:identifier:url:date:author:)`, `article.blocks = BlockParser.blocks(fromHTML:)`, `article.createdAt = ...`, `article.feed = feed`. The reader derives its lead image from the first image block in the body (see `ArticleBlockView.leadImageRef`), so embedding a `yana-img://` `<img>` as the first body element gives both the timeline thumbnail and the reader lead image. Confirm whether `Article` has a stored `summary` property (CLAUDE.md says summaries are "stored on the article"); if so set it, otherwise embed the summary as the lead paragraph — resolve this while reading the model.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import Yana

@MainActor
struct ScreenshotSeedTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func noOpWithoutLaunchArgument() async throws {
        // The test process does not pass -UITEST_SCREENSHOTS, so seeding must not run.
        let context = try inMemoryContext()
        await ScreenshotSeed.seedIfRequested(into: context)
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }

    @Test func seedInsertsCuratedLibrary() async throws {
        let context = try inMemoryContext()
        // Call the internal seeding routine directly, bypassing the launch-arg gate.
        await ScreenshotSeed.seed(into: context)

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count >= 12)
        // Every article has a block body and a createdAt spread across recent time.
        #expect(articles.allSatisfy { !$0.blocks.isEmpty })
        // Multiple distinct feeds (aggregator variety).
        let feeds = try context.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count >= 4)
        // An anchor was parked on one of the seeded articles.
        let anchor = AppSettings().timelineAnchorIdentifier
        #expect(anchor != nil)
        #expect(articles.contains { $0.identifier == anchor })
    }
}
```

> Note: split `seedIfRequested` (gate) from an internal `seed(into:)` (does the work) so the test can exercise the work without setting a process launch argument.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaTests/ScreenshotSeedTests 2>&1 | tail -20`
Expected: FAIL — cannot find `ScreenshotSeed`.

- [ ] **Step 3: Implement the seed**

Create `Yana/Utilities/ScreenshotSeed.swift` (adjust `Article`/`Feed`/`Tag`/`summary` usage to the real model signatures confirmed above):

```swift
#if DEBUG
import Foundation
import SwiftData

/// Curated, network-free library for App Store screenshots. Gated by the
/// `-UITEST_SCREENSHOTS` launch argument so it never runs on a normal launch or on the
/// `YANA_SEED_ARTICLES` performance path. Idempotent: bails if any Feed already exists.
enum ScreenshotSeed {
    static let launchArgument = "-UITEST_SCREENSHOTS"

    @MainActor
    static func seedIfRequested(into context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        await seed(into: context)
    }

    /// One curated feed per aggregator flavor, each contributing a few articles.
    private struct FeedSpec {
        let name: String
        let type: AggregatorType
        let tagName: String
        let tagColorHex: String
        let articles: [(title: String, author: String, summary: String)]
    }

    private static let specs: [FeedSpec] = [
        FeedSpec(name: "Heise Online", type: .feedContent, tagName: "Tech", tagColorHex: "#2E77D0", articles: [
            ("Apple ships on-device RSS: privacy without a server", "Jantje Cordes",
             "A new wave of local-first readers keeps your feeds entirely on the phone — no account, no cloud sync, no tracking."),
            ("Swift 6 concurrency lands across the ecosystem", "Malte Kuhr",
             "Strict concurrency checking is now the default, and libraries are racing to adopt @MainActor and Sendable."),
            ("The quiet return of the personal feed reader", "Hanna Vogt",
             "RSS never died. Here's why a focused, on-device reader beats an algorithmic timeline."),
        ]),
        FeedSpec(name: "Tagesschau", type: .feedContent, tagName: "News", tagColorHex: "#D0392E", articles: [
            ("Morning briefing: everything you missed overnight", "Redaktion",
             "The stories shaping the day, gathered while you slept."),
            ("Explainer: how aggregation keeps you in control", "Redaktion",
             "You choose the sources. The app just fetches and organizes."),
        ]),
        FeedSpec(name: "Marques on YouTube", type: .youtube, tagName: "Video", tagColorHex: "#7A2ED0", articles: [
            ("The best phone for reading in 2026", "MKBHD",
             "Screen, battery, and the underrated joy of a great reading app."),
            ("I replaced my news apps with one RSS reader", "MKBHD",
             "A week living entirely inside a self-contained feed aggregator."),
        ]),
        FeedSpec(name: "r/apple", type: .reddit, tagName: "Community", tagColorHex: "#D07A2E", articles: [
            ("What feed reader are you using in 2026?", "u/feedfan",
             "The community weighs in on native, privacy-first readers."),
            ("PSA: OPML import makes switching painless", "u/switcher",
             "Bring every subscription over in one file."),
        ]),
        FeedSpec(name: "Accidental Tech Podcast", type: .podcast, tagName: "Audio", tagColorHex: "#2EB8D0", articles: [
            ("Episode 612: The local-first renaissance", "ATP",
             "Why on-device processing is the story of the year."),
            ("Episode 611: Feeds, tags, and taste", "ATP",
             "Organizing information without an algorithm deciding for you."),
        ]),
    ]

    @MainActor
    static func seed(into context: ModelContext) async {
        // Idempotency guard.
        if let existing = try? context.fetch(FetchDescriptor<Feed>()), !existing.isEmpty { return }

        var globalIndex = 0
        var articleIdentifiers: [String] = []

        for spec in specs {
            let feed = Feed(name: spec.name, aggregatorType: spec.type,
                            identifier: "screenshot://\(spec.name)")
            context.insert(feed)

            let tag = Tag(name: spec.tagName, colorHex: spec.tagColorHex)
            context.insert(tag)
            feed.tags = [tag]

            for item in spec.articles {
                let identifier = "screenshot://article/\(globalIndex)"
                let article = Article(
                    title: item.title,
                    identifier: identifier,
                    url: "https://example.com/screenshot/\(globalIndex)",
                    date: .now,
                    author: item.author
                )
                let imageRef = await leadImageRef(for: globalIndex)
                article.blocks = BlockParser.blocks(fromHTML: body(imageRef: imageRef, item: item))
                // If Article has a stored summary field, set it here instead of (or in addition to)
                // the summary paragraph in body(): article.summary = item.summary
                article.createdAt = Date(timeIntervalSinceNow: -Double(globalIndex) * 5400)
                article.feed = feed
                article.tags = [tag]
                context.insert(article)
                articleIdentifiers.append(identifier)
                globalIndex += 1
            }
        }

        do {
            try context.save()
            // Park the anchor on the first article of the third feed (a visually rich one)
            // so the reader opens on a good hero shot.
            let anchor = articleIdentifiers.indices.contains(6)
                ? articleIdentifiers[6] : articleIdentifiers.first
            AppSettings().timelineAnchorIdentifier = anchor
            NSLog("ScreenshotSeed: inserted \(articleIdentifiers.count) articles, anchor=\(anchor ?? "nil")")
        } catch {
            NSLog("ScreenshotSeed: save failed: \(error)")
        }
    }

    private static func leadImageRef(for index: Int) async -> String {
        let data = ScreenshotImageFactory.jpeg(index: index)
        let hash = await ImageStore.shared.storeData(data, ext: "jpg")
        return "\(ReaderWeb.imageScheme)://\(hash)"
    }

    private static func body(imageRef: String, item: (title: String, author: String, summary: String)) -> String {
        // Lead image first (becomes the reader lead image + timeline thumbnail), then the
        // summary as an emphasized lead paragraph, then a couple of body paragraphs.
        """
        <img src="\(imageRef)" alt="">
        <p><strong>\(item.summary)</strong></p>
        <p>\(String(repeating: "This is curated screenshot copy that reads like a real article without depending on any network fetch. ", count: 3))</p>
        <p>\(String(repeating: "Feeds are aggregated on-device, organized with tags, and read in a clean native reader. ", count: 3))</p>
        """
    }
}
#endif
```

> If `Tag(name:colorHex:)` or `Feed.tags` / `Article.tags` differ from the above, adapt to the real API discovered when reading the models. Keep the public surface (`seedIfRequested`, `seed`, `launchArgument`) identical so the test and wiring compile.

- [ ] **Step 4: Wire the launch argument in AppDelegate**

In `Yana/YanaApp.swift`, replace the existing DEBUG seed block in `didFinishLaunchingWithOptions`:

```swift
#if DEBUG
DebugSeed.seedIfRequested(into: AppContainer.shared.mainContext)
Task { @MainActor in
    await ScreenshotSeed.seedIfRequested(into: AppContainer.shared.mainContext)
}
#endif
```

(The `ArticleStore` `didSave` observer picks up the inserted articles, so seeding asynchronously after launch is fine.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaTests/ScreenshotSeedTests 2>&1 | tail -20`
Expected: PASS (2 tests). `noOpWithoutLaunchArgument` passes because the test runner doesn't pass the arg.

- [ ] **Step 6: Commit**

```bash
xcodegen generate
git add Yana/Utilities/ScreenshotSeed.swift Yana/YanaApp.swift YanaTests/ScreenshotSeedTests.swift
git commit -m "Add ScreenshotSeed offline fixture behind -UITEST_SCREENSHOTS"
```

---

### Task 4: Accessibility identifiers for deterministic UITest navigation

Give the reader's article-list button and overflow menu, and the Settings→Feeds link, stable identifiers so the UITest navigates without depending on localized labels.

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift` (nav item setup ~line 160–192)
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (`organizeSection`, ~line 69–77)

**Interfaces:**
- Produces (consumed by Task 6 UITest): identifiers `reader.articleList`, `reader.menu`, `settings.feeds`.

- [ ] **Step 1: Add identifiers to the reader nav items**

In `configureNavigationItems()`, after each item's `accessibilityLabel`:

```swift
articleListItem.accessibilityLabel = String(localized: "Article list")
articleListItem.accessibilityIdentifier = "reader.articleList"
```

```swift
menuItem.accessibilityLabel = String(localized: "More actions")
menuItem.accessibilityIdentifier = "reader.menu"
```

- [ ] **Step 2: Add an identifier to the Feeds navigation link**

In `SettingsScreenView.organizeSection`, on the `NavigationLink` whose label is `Label("Feeds", systemImage: "list.bullet.rectangle")`, add to that link's label:

```swift
NavigationLink {
    FeedsView()
} label: {
    Label("Feeds", systemImage: "list.bullet.rectangle")
}
.accessibilityIdentifier("settings.feeds")
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift Yana/Views/Config/SettingsScreenView.swift
git commit -m "Add accessibility identifiers for screenshot UITest navigation"
```

---

### Task 5: fastlane scaffolding — install, Snapfile, SnapshotHelper

Install fastlane and lay down the `snapshot` configuration + the vendored `SnapshotHelper.swift` the UITest calls.

**Files:**
- Create: `fastlane/Snapfile`
- Create: `YanaUITests/SnapshotHelper.swift` (generated by fastlane, moved into the target)
- Modify: `.gitignore` (ignore generated screenshot output)

**Interfaces:**
- Produces (consumed by Task 6): global functions `setupSnapshot(_ app: XCUIApplication)` and `snapshot(_ name: String)` from `SnapshotHelper.swift`.

- [ ] **Step 1: Install fastlane**

Run: `brew install fastlane && fastlane --version`
Expected: prints a fastlane version (2.x). If Homebrew is unavailable, stop and report — do not fall back to system-Ruby gems (Ruby 2.6.10 is too old).

- [ ] **Step 2: Generate the snapshot helper + Snapfile skeleton**

Run: `cd fastlane 2>/dev/null || (mkdir -p fastlane && cd fastlane); fastlane snapshot init`
This creates `fastlane/SnapshotHelper.swift` and a `fastlane/Snapfile`. Move the helper into the UITest target:

Run: `git mv fastlane/SnapshotHelper.swift YanaUITests/SnapshotHelper.swift 2>/dev/null || mv fastlane/SnapshotHelper.swift YanaUITests/SnapshotHelper.swift`
(XcodeGen includes it automatically because `YanaUITests` sources the whole `YanaUITests` directory.)

- [ ] **Step 3: Write the Snapfile**

Overwrite `fastlane/Snapfile`:

```ruby
# Devices: 6.9" iPhone (1320x2868) and 13" iPad (2064x2752).
# Confirm names against `xcrun simctl list devices available`.
devices([
  "iPhone 17 Pro Max",
  "iPad Pro 13-inch (M5)"
])

languages(["en-US"])

scheme("Yana")

# Only run the screenshot UITest, not the whole UI suite.
only_testing(["YanaUITests/ScreenshotUITests"])

output_directory("./fastlane/screenshots")
clear_previous_screenshots(true)

# The fixture launch argument is set inside the UITest (launchArguments), so no extra
# launch_arguments needed here.

concurrent_simulators(false)
stop_after_first_error(true)
```

- [ ] **Step 4: Ignore generated output**

Add to `.gitignore`:

```
# fastlane screenshot output (regenerated on demand)
fastlane/screenshots/**/*.png
fastlane/screenshots/**/screenshots.html
fastlane/test_output/
```

- [ ] **Step 5: Regenerate project and build the UITest target**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build-for-testing 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **` (SnapshotHelper compiles inside the UITest target). `ScreenshotUITests` does not exist yet — that's fine for build-for-testing since the file is added in Task 6; if the build references it, do this step after Task 6 Step 1.

- [ ] **Step 6: Commit**

```bash
git add fastlane/Snapfile YanaUITests/SnapshotHelper.swift .gitignore
git commit -m "Add fastlane snapshot scaffolding + SnapshotHelper"
```

---

### Task 6: `ScreenshotUITests` capture flow + capture run

Write the UITest that launches with the fixture and snaps the four screens, then run `fastlane snapshot` to produce raw captures on both devices.

**Files:**
- Create: `YanaUITests/ScreenshotUITests.swift`

**Interfaces:**
- Consumes: `setupSnapshot`/`snapshot` (Task 5), `ScreenshotSeed.launchArgument` value `-UITEST_SCREENSHOTS` (Task 3), identifiers `reader.articleList`, `reader.menu`, `settings.feeds` (Task 4), `emptyArticlesTitle` (existing).

- [ ] **Step 1: Write the UITest**

Create `YanaUITests/ScreenshotUITests.swift`:

```swift
import XCTest

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITEST_SCREENSHOTS"]
        setupSnapshot(app)
        app.launch()

        // Shot 1 — Reader. The fixture parks the anchor on a hero article, so the app opens
        // on it. Wait for the article-list toolbar button (only present on the loaded reader).
        let articleList = app.buttons["reader.articleList"]
        XCTAssertTrue(articleList.waitForExistence(timeout: 20), "reader did not load")
        snapshot("01_Reader")

        // Shot 2 — Timeline / article list.
        articleList.tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "article list did not open")
        snapshot("02_Timeline")

        // Shot 3 — Search.
        searchField.tap()
        searchField.typeText("reader")
        // Let results settle (250ms debounce in ArticleListView).
        Thread.sleep(forTimeInterval: 1.0)
        snapshot("03_Search")

        // Dismiss the article-list sheet.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.swipeDown(velocity: .fast)

        // Shot 4 — Feeds. Open overflow menu -> Settings -> Feeds.
        let menu = app.buttons["reader.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "reader menu missing after dismiss")
        menu.tap()
        app.buttons["Settings"].tap()
        let feeds = app.otherElements["settings.feeds"].exists
            ? app.otherElements["settings.feeds"]
            : app.buttons["settings.feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10), "Feeds link missing")
        feeds.tap()
        // Feeds screen title confirms navigation.
        XCTAssertTrue(app.navigationBars["Feeds"].waitForExistence(timeout: 10), "Feeds screen missing")
        snapshot("04_Feeds")
    }
}
```

> The `.accessibilityIdentifier` on a SwiftUI `NavigationLink` may surface as either a button or an otherElement depending on iOS — the test tries both. If neither resolves during the run, fall back to `app.buttons["Feeds"].tap()` (English label) and note it.

- [ ] **Step 2: Regenerate and run the UITest directly first (fast feedback)**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:YanaUITests/ScreenshotUITests 2>&1 | tail -30`
Expected: `Test Suite 'ScreenshotUITests' ... passed`. If a `snapshot()` step fails to find an element, use `superpowers:systematic-debugging` — inspect with `app.debugDescription` — before adjusting selectors. Do not weaken assertions to force a pass.

- [ ] **Step 3: Run fastlane snapshot (capture only)**

Run: `fastlane snapshot 2>&1 | tail -30`
Expected: raw PNGs in `fastlane/screenshots/en-US/` — `01_Reader`, `02_Timeline`, `03_Search`, `04_Feeds` for both `iPhone 17 Pro Max` and `iPad Pro 13-inch (M5)`.

- [ ] **Step 4: Verify resolutions**

Run: `cd fastlane/screenshots/en-US && for f in *.png; do echo "$f: $(sips -g pixelWidth -g pixelHeight "$f" | awk 'NR>1{print $2}' | paste -sd x -)"; done`
Expected: iPhone shots 1320×2868, iPad shots 2064×2752 (portrait). Report actual values.

- [ ] **Step 5: Commit the test (screenshots themselves are gitignored)**

```bash
git add YanaUITests/ScreenshotUITests.swift
git commit -m "Add ScreenshotUITests capture flow"
```

---

### Task 7: frameit configuration + Fastfile lane + end-to-end run

Add device frames and English captions, wired into a single `fastlane screenshots` lane.

**Files:**
- Create: `fastlane/Fastfile`
- Create: `fastlane/screenshots/Framefile.json`
- Create: `fastlane/screenshots/en-US/title.strings`

**Interfaces:**
- Produces: `fastlane screenshots` lane running capture + frame.

- [ ] **Step 1: Download device frames**

Run: `fastlane frameit download_frames 2>&1 | tail -5`
Expected: frames cached under `~/.frameit/`. Note in output whether frames for the exact devices exist; frameit matches by device name embedded in the screenshot metadata.

- [ ] **Step 2: Write the Framefile**

Create `fastlane/screenshots/Framefile.json`:

```json
{
  "default": {
    "background": "#0B1020",
    "padding": 80,
    "title": {
      "color": "#FFFFFF",
      "font_size": 96
    },
    "show_complete_frame": false,
    "title_below_image": false
  },
  "data": []
}
```

- [ ] **Step 3: Write the captions**

Create `fastlane/screenshots/en-US/title.strings`:

```
"01_Reader" = "Read it your way — clean, native, no browser";
"02_Timeline" = "Everything you follow, in one timeline";
"03_Search" = "Find any article instantly";
"04_Feeds" = "RSS, YouTube, Reddit & podcasts — one app, fully on-device";
```

- [ ] **Step 4: Write the Fastfile**

Create `fastlane/Fastfile`:

```ruby
default_platform(:ios)

platform :ios do
  desc "Capture and frame App Store screenshots (en-US, 6.9\" iPhone + 13\" iPad)"
  lane :screenshots do
    capture_screenshots
    frame_screenshots(white: false)
  end
end
```

- [ ] **Step 5: Run the full pipeline end-to-end**

Run: `fastlane screenshots 2>&1 | tail -40`
Expected: for each raw PNG a `*_framed.png` beside it in `fastlane/screenshots/en-US/`.

- [ ] **Step 6: Verify framed output exists and note any missing frames**

Run: `ls -1 fastlane/screenshots/en-US/*_framed.png | wc -l && ls -1 fastlane/screenshots/en-US/*_framed.png`
Expected: 8 framed PNGs (4 shots × 2 devices). If frameit skipped a device for lack of a frame, report it — per the spec, the unframed capture for that device is the store-valid fallback.

- [ ] **Step 7: Commit fastlane config**

```bash
git add fastlane/Fastfile fastlane/screenshots/Framefile.json fastlane/screenshots/en-US/title.strings
git commit -m "Add frameit config + fastlane screenshots lane"
```

---

### Task 8: Documentation

Make regeneration discoverable.

**Files:**
- Modify: `CLAUDE.md` (Commands section)
- Create or modify: `README.md` (a short "App Store screenshots" section) — if no README exists, create a minimal one.

- [ ] **Step 1: Document the command in CLAUDE.md**

Under `## Commands` → add a subsection:

```markdown
### App Store screenshots
- `fastlane screenshots` — capture + frame App Store screenshots (en-US, 6.9" iPhone + 13" iPad). Requires `brew install fastlane`.
- Content is a DEBUG-only offline fixture (`ScreenshotSeed`) triggered by the `-UITEST_SCREENSHOTS` launch argument the `ScreenshotUITests` capture flow passes — no network, fully reproducible.
- Output (gitignored): `fastlane/screenshots/en-US/*_framed.png`. Captions live in `fastlane/screenshots/en-US/title.strings`.
```

- [ ] **Step 2: Add a README section** (create `README.md` if absent, else append)

```markdown
## App Store screenshots

Generate framed, captioned marketing screenshots:

```bash
brew install fastlane   # first time only
fastlane screenshots
```

This runs the `ScreenshotUITests` capture flow against an offline content fixture
(`ScreenshotSeed`, DEBUG-only, gated by the `-UITEST_SCREENSHOTS` launch argument) on the
6.9" iPhone and 13" iPad simulators, then frames the results with captions from
`fastlane/screenshots/en-US/title.strings`. Output lands in `fastlane/screenshots/en-US/`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document App Store screenshot generation"
```

---

## Self-Review

**Spec coverage:**
- Deliverable (framed + captioned) → Task 7. ✓
- Toolchain (fastlane snapshot + frameit) → Tasks 5, 7. ✓
- Devices (6.9″ iPhone + 13″ iPad) → Snapfile (Task 5), verified in Task 6 Step 4. ✓
- English only → Snapfile `languages(["en-US"])`, `title.strings`. ✓
- Shots ordered Reader/Timeline/Search/Feeds → Task 6. ✓
- Content fixture (curated, offline, tags, AI summary, anchor, local images) → Tasks 1–3. **Refinement:** lead images are generated programmatically (`ScreenshotImageFactory`) rather than bundled binaries — better (reproducible, no licensing, no network); noted in Global Constraints. ✓
- Accessibility identifiers → Task 4. ✓
- fastlane wiring (Snapfile/Fastfile/output) → Tasks 5, 7. **Refinement:** install via Homebrew, not a Gemfile, because system Ruby is 2.6.10; noted in Global Constraints. ✓
- Docs → Task 8. ✓
- Verification (8 framed PNGs, valid resolutions, non-empty screens, build stays green) → Task 6 Steps 2/4, Task 7 Step 6. ✓
- Out of scope (de, 6.5″, CI upload, privacy shot) → not planned. ✓

**Placeholder scan:** No TBD/TODO. Two explicit "confirm against the real model/simulator" notes (model initializers in Task 3, sim names in Task 5) are deliberate verification steps, not placeholders — each has a concrete fallback.

**Type consistency:** `storeData(_:ext:)`, `ScreenshotImageFactory.jpeg(index:)`, `ScreenshotSeed.seedIfRequested`/`seed`/`launchArgument`, and identifiers `reader.articleList`/`reader.menu`/`settings.feeds` are used consistently across producing and consuming tasks. `-UITEST_SCREENSHOTS` matches between Task 3 and Task 6.
