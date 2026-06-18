# NetNewsWire Reader Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Yana's SwiftUI reader with a faithful port of NetNewsWire's UIKit reader (opaque native chrome + automatic web-view insets, tap-to-hide full-screen, native browser, and the `.nnwtheme` theme system), fixing the title-behind-bar and high-bottom-bar bugs.

**Architecture:** A UIKit reader (`ReaderArticleViewController` hosting a `UIPageViewController` of `ReaderWebViewController`s) is wrapped in a `UINavigationController` and embedded in SwiftUI via `ReaderHostView` (`UIViewControllerRepresentable`). A thin SwiftUI `ReaderScreen` owns the `@Query` timeline, position-memory, and the existing Settings/Filter sheets. Article HTML is produced by a ported `ArticleRenderer` + `MacroProcessor` driving NNW's `.nnwtheme` templates/stylesheets, selected through a ported, bundled-only `ArticleThemesManager`.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, UIKit, WebKit, SafariServices, Swift Testing, XcodeGen.

## Global Constraints

- Platform: iOS 26.0+ (iPhone and iPad); full-screen reading gated to iPhone idiom.
- Swift 6 strict concurrency; annotate UIKit/web types `@MainActor`.
- Reference source (this session): `/private/tmp/nnw-ref` — copy resource files verbatim from here.
- All new user-facing strings MUST be added to `Yana/Resources/Localizable.xcstrings` with a German (`de`) translation marked `"state" : "translated"`. German uses Apple style (infinitive for actions, no "Du"/"Sie").
- After any change to files-on-disk that the Xcode project must include, run `xcodegen generate`.
- Build check command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- New reader code lives under `Yana/Reader/`; rendering resources under `Yana/Resources/ArticleRendering/`; themes under `Yana/Resources/Themes/`.
- Reuse existing helpers — do NOT reimplement: `ReaderWeb` (base origin / `yana-img` scheme), `ImageSchemeHandler`, `ContentFormatter.escapeHTML`, `ArticleHeaderLogo`, `TagFilter`, `TimelineAnchor`, `TimelinePageIndex`, `ShareSheet`, `SyncFailureSummary`, `AggregationService`.

---

## File Structure

**New (Swift):**
- `Yana/Reader/MacroProcessor.swift` — `[[macro]]` substitution (pure).
- `Yana/Reader/ArticleTextSize.swift` — text-size enum → CSS class.
- `Yana/Reader/ArticleThemePlist.swift` — `Info.plist` decode model.
- `Yana/Reader/ArticleTheme.swift` — one theme (template + css + metadata).
- `Yana/Reader/ArticleThemesManager.swift` — bundled-theme registry + current selection.
- `Yana/Reader/ArticleRenderer.swift` — `Article` + theme → `(style, html, title, baseURL)`.
- `Yana/Reader/ReaderWebViewController.swift` — one article's `WKWebView` (insets, links, full-screen tap-zones, pull-to-refresh).
- `Yana/Reader/ReaderArticleViewController.swift` — pager + nav bar + toolbar + full-screen control.
- `Yana/Reader/ReaderHostView.swift` — `UIViewControllerRepresentable` bridge + `ReaderScreen` SwiftUI wrapper.

**New (resources):**
- `Yana/Resources/ArticleRendering/{core.css,stylesheet.css,template.html,page.html}`
- `Yana/Resources/Themes/{Appanoose,Biblioteca,Hyperlegible,NewsFax,Promenade,Sepia,Tiqoe Dark,Verdana Revival}.nnwtheme/`

**Modified:**
- `Yana/Models/AppSettings.swift` — reader keys.
- `Yana/ContentView.swift` — host `ReaderScreen`.
- `Yana/Views/ArticleDetailView.swift` — render-only web view.
- `Yana/Views/Config/SettingsScreenView.swift` — Reader section.
- `project.yml` — bundle resources.
- `Yana/Resources/Localizable.xcstrings` — new strings.

**Removed:** `Yana/Views/ArticleReaderView.swift`, `Yana/Views/ArticlePagerView.swift`, `Yana/Views/ArticleContentView.swift`, `Yana/Views/ArticleWebView.swift`, `Yana/Views/LinkWebView.swift`.

**Tests:** `YanaTests/MacroProcessorTests.swift`, `YanaTests/ArticleRendererTests.swift`, `YanaTests/ArticleThemesManagerTests.swift`.

---

## Task 1: MacroProcessor

**Files:**
- Create: `Yana/Reader/MacroProcessor.swift`
- Test: `YanaTests/MacroProcessorTests.swift`

**Interfaces:**
- Produces: `enum MacroProcessor { static func renderedText(withTemplate: String, substitutions: [String: String], macroStart: String = "[[", macroEnd: String = "]]") throws -> String }`. Unknown macros are left verbatim (e.g. `[[unknown]]`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Yana

struct MacroProcessorTests {
    @Test func substitutesKnownMacrosAndLeavesUnknownVerbatim() throws {
        let out = try MacroProcessor.renderedText(
            withTemplate: "<h1>[[title]]</h1><p>[[missing]]</p>",
            substitutions: ["title": "Hello"]
        )
        #expect(out == "<h1>Hello</h1><p>[[missing]]</p>")
    }

    @Test func emptyDelimiterThrows() {
        #expect(throws: MacroProcessorError.self) {
            _ = try MacroProcessor.renderedText(withTemplate: "x", substitutions: [:], macroStart: "", macroEnd: "]]")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -i "MacroProcessor\|cannot find\|error:"`
Expected: FAIL — `cannot find 'MacroProcessor' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum MacroProcessorError: Error, Sendable {
    case emptyMacroDelimiter
}

/// Replaces `[[macro]]` tokens in a template with values from a dictionary. Unknown macros
/// are left as-is. Ported from NetNewsWire's RSCore MacroProcessor.
enum MacroProcessor {
    static func renderedText(
        withTemplate template: String,
        substitutions: [String: String],
        macroStart: String = "[[",
        macroEnd: String = "]]"
    ) throws -> String {
        if macroStart.isEmpty || macroEnd.isEmpty {
            throw MacroProcessorError.emptyMacroDelimiter
        }

        var result = String()
        var index = template.startIndex

        while true {
            guard let startRange = template[index...].range(of: macroStart) else { break }
            result.append(contentsOf: template[index..<startRange.lowerBound])

            guard let endRange = template[startRange.upperBound...].range(of: macroEnd) else {
                index = startRange.lowerBound
                break
            }

            let key = String(template[startRange.upperBound..<endRange.lowerBound])
            result.append(substitutions[key] ?? "\(macroStart)\(key)\(macroEnd)")
            index = endRange.upperBound
        }

        result.append(contentsOf: template[index...])
        return result
    }
}
```

- [ ] **Step 4: Wire the new files into the project and run the test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -5`
Expected: PASS (both MacroProcessor tests green).

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/MacroProcessor.swift YanaTests/MacroProcessorTests.swift Yana.xcodeproj
git commit -m "feat(reader): port MacroProcessor for template substitution"
```

---

## Task 2: ArticleTextSize

**Files:**
- Create: `Yana/Reader/ArticleTextSize.swift`

**Interfaces:**
- Produces: `enum ArticleTextSize: Int, CaseIterable, Identifiable { case small=1, medium=2, large=3, xlarge=4, xxlarge=5; var cssClass: String; var displayName: String }`. `cssClass` values: `smallText`, `mediumText`, `largeText`, `xlargeText`, `xxlargeText` (lowercase — matching `stylesheet.css`; NNW's capital-L variant is a latent bug we fix here).

- [ ] **Step 1: Write the implementation**

```swift
import Foundation

/// User-selectable article body text size. CSS class names match the `.smallText … .xxlargeText`
/// rules in stylesheet.css. Ported/adapted from NetNewsWire's ArticleTextSize.
enum ArticleTextSize: Int, CaseIterable, Identifiable, Sendable {
    case small = 1
    case medium = 2
    case large = 3
    case xlarge = 4
    case xxlarge = 5

    var id: Int { rawValue }

    var cssClass: String {
        switch self {
        case .small: "smallText"
        case .medium: "mediumText"
        case .large: "largeText"
        case .xlarge: "xlargeText"
        case .xxlarge: "xxlargeText"
        }
    }

    var displayName: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        case .xlarge: String(localized: "Extra Large")
        case .xxlarge: String(localized: "Extra Extra Large")
        }
    }
}
```

- [ ] **Step 2: Add the 5 new strings to the catalog**

Add to `Yana/Resources/Localizable.xcstrings` (English key = value, plus `de`): `Small`→`Klein`, `Medium`→`Mittel`, `Large`→`Groß`, `Extra Large`→`Sehr groß`, `Extra Extra Large`→`Extra groß`. Each language entry marked `"state" : "translated"`.

- [ ] **Step 3: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ArticleTextSize.swift Yana/Resources/Localizable.xcstrings Yana.xcodeproj
git commit -m "feat(reader): add ArticleTextSize with localized names"
```

---

## Task 3: Bundle rendering resources & theme bundles

**Files:**
- Create (copied verbatim): `Yana/Resources/ArticleRendering/core.css`, `stylesheet.css`, `template.html`
- Create (adapted): `Yana/Resources/ArticleRendering/page.html`
- Create (copied dirs): `Yana/Resources/Themes/*.nnwtheme` (8 bundles)
- Modify: `project.yml`

**Interfaces:**
- Produces: bundle resources resolvable via `Bundle.main.url(forResource:withExtension:)` — `core`/`stylesheet` (`css`), `template`/`page` (`html`) — and 8 `.nnwtheme` directories resolvable via `Bundle.main.url(forResource:withExtension:"nnwtheme")`.

- [ ] **Step 1: Copy the shared rendering files**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
mkdir -p Yana/Resources/ArticleRendering Yana/Resources/Themes
cp "/private/tmp/nnw-ref/Shared/Article Rendering/core.css" Yana/Resources/ArticleRendering/core.css
cp "/private/tmp/nnw-ref/Shared/Article Rendering/stylesheet.css" Yana/Resources/ArticleRendering/stylesheet.css
cp "/private/tmp/nnw-ref/Shared/Article Rendering/template.html" Yana/Resources/ArticleRendering/template.html
cp -R /private/tmp/nnw-ref/Resources/Themes/*.nnwtheme Yana/Resources/Themes/
ls Yana/Resources/Themes
```
Expected: the 8 `.nnwtheme` directories listed.

- [ ] **Step 2: Create the adapted outer page template (no JS)**

Create `Yana/Resources/ArticleRendering/page.html` (NNW's page.html minus the `<script>` tags and the `processPage()`/`window.scrollTo` bootstrap — we ported no JS):

```html
<html dir="auto">
	<head>
		<title>[[title]]</title>
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<style>
			[[style]]
		</style>
		<base href="[[baseURL]]">
	</head>
	<body>
		[[body]]
	</body>
</html>
```

- [ ] **Step 3: Wire resources into project.yml**

Inspect the `Yana` target's `sources:` in `project.yml`. The `Yana/Resources` folder is almost certainly already a source (the `.xcstrings` lives there). Confirm `.nnwtheme` folders are treated as **folder references** (copied as directories, not flattened) by adding an explicit entry. Add under the Yana target `sources:` list:

```yaml
    - path: Yana/Resources/Themes
      type: folder
```

(A `type: folder` entry copies the directory tree as a blue folder reference, preserving each `.nnwtheme` bundle's internal `template.html`/`stylesheet.css`/`Info.plist`. The `ArticleRendering` `.css`/`.html` files are picked up by the existing `Yana/Resources` source rule as individual resources.)

- [ ] **Step 4: Generate and verify resources are in the bundle**

```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify bundle layout in the built app**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Yana.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1)
ls "$APP" | grep -E "stylesheet.css|core.css|template.html|page.html"
ls "$APP/Themes" 2>/dev/null || ls "$APP" | grep nnwtheme
```
Expected: the 4 rendering files present, and the 8 `.nnwtheme` bundles present (under `Themes/` if folder-referenced).

> If the `.nnwtheme` folders are flattened or missing, fix the `project.yml` entry (use `type: folder` for `Yana/Resources/Themes`) and repeat Steps 4–5 before continuing. The theme code in later tasks depends on this layout.

- [ ] **Step 6: Commit**

```bash
git add Yana/Resources/ArticleRendering Yana/Resources/Themes project.yml Yana.xcodeproj
git commit -m "feat(reader): bundle NNW rendering CSS/templates and 8 nnwtheme themes"
```

---

## Task 4: ArticleThemePlist + ArticleTheme

**Files:**
- Create: `Yana/Reader/ArticleThemePlist.swift`
- Create: `Yana/Reader/ArticleTheme.swift`

**Interfaces:**
- Consumes: bundled `core.css`, `stylesheet.css`, `template.html` (Task 3); `.nnwtheme` bundles (Task 3).
- Produces:
  - `struct ArticleThemePlist: Codable, Equatable, Sendable { let name, themeIdentifier, creatorHomePage, creatorName: String; let version: Int }`
  - `struct ArticleTheme: Equatable, Sendable { static let defaultTheme: ArticleTheme; static let nnwThemeSuffix = ".nnwtheme"; static let defaultThemeName: String; let template: String?; let css: String?; let name: String; init(); init(url: URL) throws; static func themeNameForPath(_:) -> String; static func pathIsPathForThemeName(_:path:) -> Bool }`

- [ ] **Step 1: Create ArticleThemePlist.swift**

```swift
import Foundation

/// Decodes a `.nnwtheme` bundle's Info.plist. Ported from NetNewsWire.
struct ArticleThemePlist: Codable, Equatable, Sendable {
    let name: String
    let themeIdentifier: String
    let creatorHomePage: String
    let creatorName: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case themeIdentifier = "ThemeIdentifier"
        case creatorHomePage = "CreatorHomePage"
        case creatorName = "CreatorName"
        case version = "Version"
    }
}
```

- [ ] **Step 2: Create ArticleTheme.swift**

```swift
import Foundation

/// One article theme: the body `template.html` and combined `core.css` + theme `stylesheet.css`.
/// The default theme uses the app's bundled `stylesheet.css`/`template.html`; named themes load
/// from a bundled `.nnwtheme` folder. Adapted from NetNewsWire (local bundles only).
struct ArticleTheme: Equatable, Sendable {

    static let nnwThemeSuffix = ".nnwtheme"
    static let defaultThemeName = String(localized: "Default")

    let url: URL?
    let template: String?
    let css: String?
    let name: String

    /// The built-in default theme: app `core.css` + `stylesheet.css` + `template.html`.
    static let defaultTheme = ArticleTheme()

    private init() {
        self.url = nil
        self.name = Self.defaultThemeName
        let core = Self.bundledString("core", "css")
        let sheet = Self.bundledString("stylesheet", "css")
        self.css = (core ?? "") + "\n" + (sheet ?? "")
        self.template = Self.bundledString("template", "html")
    }

    /// A named theme loaded from a `.nnwtheme` folder URL. core.css is prepended so themes share
    /// the base rules; the theme supplies its own stylesheet.css + template.html.
    init(url: URL) throws {
        self.url = url
        self.name = Self.themeNameForPath(url.path)

        let coreURL = Bundle.main.url(forResource: "core", withExtension: "css")!
        let core = Self.stringAtPath(coreURL.path) ?? ""
        if let sheet = Self.stringAtPath(url.appendingPathComponent("stylesheet.css").path) {
            self.css = core + "\n" + sheet
        } else {
            self.css = nil
        }
        self.template = Self.stringAtPath(url.appendingPathComponent("template.html").path)

        let data = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
        _ = try PropertyListDecoder().decode(ArticleThemePlist.self, from: data)
    }

    private static func bundledString(_ name: String, _ ext: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: ext) else { return nil }
        return stringAtPath(path)
    }

    static func stringAtPath(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var encoding = String.Encoding.utf8
        return try? String(contentsOfFile: path, usedEncoding: &encoding)
    }

    static func themeNameForPath(_ path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        if filename.hasSuffix(nnwThemeSuffix) {
            return String(filename.dropLast(nnwThemeSuffix.count))
        }
        return filename
    }

    static func pathIsPathForThemeName(_ themeName: String, path: String) -> Bool {
        themeNameForPath(path) == themeName
    }
}
```

- [ ] **Step 3: Add the "Default" string to the catalog**

Add to `Localizable.xcstrings`: `Default`→ de `Standard`, marked `translated`.

- [ ] **Step 4: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ArticleThemePlist.swift Yana/Reader/ArticleTheme.swift Yana/Resources/Localizable.xcstrings Yana.xcodeproj
git commit -m "feat(reader): port ArticleTheme + ArticleThemePlist (bundled themes)"
```

---

## Task 5: ArticleThemesManager

**Files:**
- Create: `Yana/Reader/ArticleThemesManager.swift`
- Test: `YanaTests/ArticleThemesManagerTests.swift`

**Interfaces:**
- Consumes: `ArticleTheme` (Task 4), `AppSettings.readerThemeName` (Task 8 — but this task introduces the manager keyed by a plain UserDefaults string to avoid an ordering dependency; Task 8 wires the typed accessor and Task 9's picker uses it).
- Produces: `@MainActor final class ArticleThemesManager { static let shared: ArticleThemesManager; var themeNames: [String] { get }; var currentThemeName: String { get set }; var currentTheme: ArticleTheme { get }; static let currentThemeDidChange: Notification.Name }`. `themeNames` = `["Default"] + bundled .nnwtheme names`, sorted case-insensitively with "Default" first. Setting `currentThemeName` to an unknown name falls back to Default. Setting it posts `currentThemeDidChange`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Yana

@MainActor
struct ArticleThemesManagerTests {
    @Test func enumeratesDefaultPlusBundledThemes() {
        let names = ArticleThemesManager.shared.themeNames
        #expect(names.first == ArticleTheme.defaultThemeName)
        #expect(names.contains("Sepia"))
        #expect(names.contains("Promenade"))
        #expect(names.count >= 9) // Default + 8 bundled
    }

    @Test func switchingThemePersistsAndResolves() {
        let manager = ArticleThemesManager.shared
        manager.currentThemeName = "Sepia"
        #expect(manager.currentThemeName == "Sepia")
        #expect(manager.currentTheme.name == "Sepia")
        #expect(manager.currentTheme.css?.isEmpty == false)
        manager.currentThemeName = ArticleTheme.defaultThemeName // reset for other tests
    }

    @Test func unknownThemeFallsBackToDefault() {
        let manager = ArticleThemesManager.shared
        manager.currentThemeName = "NoSuchTheme-xyz"
        #expect(manager.currentThemeName == ArticleTheme.defaultThemeName)
        manager.currentThemeName = ArticleTheme.defaultThemeName
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -i "ArticleThemesManager\|cannot find\|error:"`
Expected: FAIL — `cannot find 'ArticleThemesManager' in scope`.

- [ ] **Step 3: Implement ArticleThemesManager**

```swift
import Foundation

/// Registry of bundled article themes plus the user's current selection. Adapted from
/// NetNewsWire to load only app-bundled themes (no Themes folder, no import/download).
@MainActor
final class ArticleThemesManager {
    static let shared = ArticleThemesManager()

    static let currentThemeDidChange = Notification.Name("YanaCurrentArticleThemeDidChange")

    private static let themeNameKey = "settings.readerThemeName"

    private(set) var themeNames: [String]
    private(set) var currentTheme: ArticleTheme

    var currentThemeName: String {
        get {
            UserDefaults.standard.string(forKey: Self.themeNameKey) ?? ArticleTheme.defaultThemeName
        }
        set {
            guard newValue != UserDefaults.standard.string(forKey: Self.themeNameKey) else { return }
            UserDefaults.standard.set(newValue, forKey: Self.themeNameKey)
            updateCurrentTheme()
            NotificationCenter.default.post(name: Self.currentThemeDidChange, object: self)
        }
    }

    private init() {
        self.themeNames = Self.allThemeNames()
        self.currentTheme = ArticleTheme.defaultTheme
        updateCurrentTheme()
    }

    /// Resolve a theme by name; nil if not bundled. "Default" → built-in theme.
    func theme(named themeName: String) -> ArticleTheme? {
        if themeName == ArticleTheme.defaultThemeName {
            return ArticleTheme.defaultTheme
        }
        guard let url = Bundle.main.url(forResource: themeName, withExtension: ArticleTheme.nnwThemeSuffix) else {
            return nil
        }
        return try? ArticleTheme(url: url)
    }

    private func updateCurrentTheme() {
        var name = currentThemeName
        if !themeNames.contains(name) {
            name = ArticleTheme.defaultThemeName
            UserDefaults.standard.set(name, forKey: Self.themeNameKey)
        }
        currentTheme = theme(named: name) ?? ArticleTheme.defaultTheme
    }

    private static func allThemeNames() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: ArticleTheme.nnwThemeSuffix, subdirectory: nil) ?? []
        let bundled = urls.map { ArticleTheme.themeNameForPath($0.path) }
            .sorted { $0.compare($1, options: .caseInsensitive) == .orderedAscending }
        return [ArticleTheme.defaultThemeName] + bundled
    }
}
```

> Note: `Bundle.main.urls(forResourcesWithExtension:subdirectory:)` finds `.nnwtheme` folders whether they live at the bundle root or under a `Themes/` folder reference. If Task 3 Step 5 showed them under `Themes/`, pass `subdirectory: "Themes"` instead — adjust here and re-run the test.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -iE "ArticleThemesManager|Test Suite.*passed|failed"`
Expected: the 3 ArticleThemesManager tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ArticleThemesManager.swift YanaTests/ArticleThemesManagerTests.swift Yana.xcodeproj
git commit -m "feat(reader): port ArticleThemesManager (bundled themes + current selection)"
```

---

## Task 6: ArticleRenderer

**Files:**
- Create: `Yana/Reader/ArticleRenderer.swift`
- Test: `YanaTests/ArticleRendererTests.swift`

**Interfaces:**
- Consumes: `MacroProcessor` (Task 1), `ArticleTheme` (Task 4), `ArticleTextSize` (Task 2), `Article`/`Feed` models, `ReaderWeb`, `ContentFormatter.escapeHTML`.
- Produces: `@MainActor enum ArticleRenderer { typealias Rendering = (style: String, html: String, title: String, baseURL: String); static func articleHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize) -> Rendering; static func fullPageHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize) -> String }`. `fullPageHTML` substitutes `style`/`body`/`title`/`baseURL` into the bundled `page.html`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import SwiftData
@testable import Yana

@MainActor
struct ArticleRendererTests {
    private func makeArticle() -> Article {
        let feed = Feed()
        feed.name = "Example Feed"
        feed.logoHash = "abc123"
        let article = Article()
        article.title = "Hello & Welcome"
        article.author = "Jane Doe"
        article.url = "https://example.com/post/1"
        article.content = "<p>Body text here.</p>"
        article.date = Date(timeIntervalSince1970: 1_700_000_000)
        article.feed = feed
        return article
    }

    @Test func rendersTitleBodyBylineAndAvatar() {
        let r = ArticleRenderer.articleHTML(article: makeArticle(), theme: .defaultTheme, textSize: .medium)
        #expect(r.html.contains("Hello &amp; Welcome"))
        #expect(r.html.contains("Body text here."))
        #expect(r.html.contains("Jane Doe"))
        #expect(r.html.contains("Example Feed"))
        #expect(r.html.contains("yana-img://abc123"))
        #expect(r.html.contains("mediumText"))
        #expect(r.title == "Hello &amp; Welcome")
        #expect(r.baseURL == "https://example.com")
    }

    @Test func emptyAuthorAndLogoRenderCleanly() {
        let article = makeArticle()
        article.author = ""
        article.feed?.logoHash = nil
        let r = ArticleRenderer.articleHTML(article: article, theme: .defaultTheme, textSize: .large)
        #expect(!r.html.contains("yana-img://"))
        #expect(r.html.contains("largeText"))
    }

    @Test func fullPageEmbedsStyleAndBody() {
        let html = ArticleRenderer.fullPageHTML(article: makeArticle(), theme: .defaultTheme, textSize: .medium)
        #expect(html.contains("<style>"))
        #expect(html.contains("Body text here."))
        #expect(!html.contains("<script")) // JS intentionally dropped
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -i "ArticleRenderer\|cannot find\|error:"`
Expected: FAIL — `cannot find 'ArticleRenderer' in scope`.

- [ ] **Step 3: Implement ArticleRenderer**

```swift
import Foundation
import UIKit

/// Renders a Yana `Article` into themed HTML using NNW's template + stylesheet macros.
/// Adapted from NetNewsWire's ArticleRenderer for Yana's `Article`/`Feed` model.
@MainActor
enum ArticleRenderer {
    typealias Rendering = (style: String, html: String, title: String, baseURL: String)

    /// Body HTML (theme template filled) + resolved CSS + title + base URL.
    static func articleHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize) -> Rendering {
        let title = ContentFormatter.escapeHTML(article.title)
        let style = (try? MacroProcessor.renderedText(
            withTemplate: theme.css ?? "",
            substitutions: styleSubstitutions()
        )) ?? (theme.css ?? "")
        let html = (try? MacroProcessor.renderedText(
            withTemplate: theme.template ?? "",
            substitutions: articleSubstitutions(article: article, title: title, textSize: textSize)
        )) ?? ""
        return (style, html, title, baseURL(for: article))
    }

    /// Complete HTML document: page.html with `style`/`body`/`title`/`baseURL` substituted.
    static func fullPageHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize) -> String {
        let rendering = articleHTML(article: article, theme: theme, textSize: textSize)
        let page = ArticleTheme.stringAtPath(Bundle.main.path(forResource: "page", ofType: "html") ?? "") ?? ""
        return (try? MacroProcessor.renderedText(withTemplate: page, substitutions: [
            "title": rendering.title,
            "style": rendering.style,
            "body": rendering.html,
            "baseURL": rendering.baseURL
        ])) ?? ""
    }

    // MARK: - Substitutions

    private static func articleSubstitutions(article: Article, title: String, textSize: ArticleTextSize) -> [String: String] {
        var d = [String: String]()
        let link = article.url

        d["title"] = title
        d["preferred_link"] = link
        d["external_link_label"] = ""
        d["external_link_stripped"] = ""
        d["external_link"] = ""
        d["body"] = article.content
        d["text_size_class"] = textSize.cssClass

        if let hash = article.feed?.logoHash, !hash.isEmpty {
            d["avatar_src"] = "\(ReaderWeb.imageScheme)://\(hash)"
        } else {
            d["avatar_src"] = ""
        }

        d["dateline_style"] = title.isEmpty ? "articleDatelineTitle" : "articleDateline"
        d["feed_link_title"] = ContentFormatter.escapeHTML(article.feed?.name ?? "")
        d["feed_link"] = baseURL(for: article)
        d["byline"] = ContentFormatter.escapeHTML(article.author)

        let date = article.date
        d["datetime_long"] = longDateTime.string(from: date)
        d["datetime_medium"] = mediumDateTime.string(from: date)
        d["datetime_short"] = shortDateTime.string(from: date)
        d["date_long"] = longDate.string(from: date)
        d["date_medium"] = mediumDate.string(from: date)
        d["date_short"] = shortDate.string(from: date)
        d["time_long"] = longTime.string(from: date)
        d["time_medium"] = mediumTime.string(from: date)
        d["time_short"] = shortTime.string(from: date)
        return d
    }

    private static func styleSubstitutions() -> [String: String] {
        ["font-size": String(describing: UIFont.preferredFont(forTextStyle: .body).pointSize)]
    }

    /// scheme://host of the article URL, used as both base href and feed link. Empty if unparseable
    /// or non-http(s).
    private static func baseURL(for article: Article) -> String {
        guard var comps = URLComponents(string: article.url) else { return "" }
        comps.fragment = nil
        comps.path = ""
        comps.query = nil
        guard let url = comps.url, url.scheme == "http" || url.scheme == "https" else { return "" }
        return url.absoluteString
    }

    // MARK: - Formatters

    private static func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter(); f.dateStyle = date; f.timeStyle = time; return f
    }
    private static let longDateTime = formatter(.long, .medium)
    private static let mediumDateTime = formatter(.medium, .short)
    private static let shortDateTime = formatter(.short, .short)
    private static let longDate = formatter(.long, .none)
    private static let mediumDate = formatter(.medium, .none)
    private static let shortDate = formatter(.short, .none)
    private static let longTime = formatter(.none, .long)
    private static let mediumTime = formatter(.none, .medium)
    private static let shortTime = formatter(.none, .short)
}
```

> Note on `baseURL`: clearing `path` yields `https://example.com` (no trailing slash) for `https://example.com/post/1`, matching the test. If `URLComponents` emits a trailing slash on some inputs, the test will catch it — trim a trailing `/` if needed.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -iE "ArticleRenderer|passed|failed"`
Expected: the 3 ArticleRenderer tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ArticleRenderer.swift YanaTests/ArticleRendererTests.swift Yana.xcodeproj
git commit -m "feat(reader): port ArticleRenderer mapping Yana models to NNW templates"
```

---

## Task 7: AppSettings reader keys

**Files:**
- Modify: `Yana/Models/AppSettings.swift`

**Interfaces:**
- Produces on `AppSettings`: `var readerThemeName: String` (default `ArticleTheme.defaultThemeName`), `var articleTextSize: ArticleTextSize` (default `.medium`), `var useSystemBrowser: Bool` (default false), `var articleFullscreenEnabled: Bool` (default false). `readerThemeName` reads/writes the SAME UserDefaults key `"settings.readerThemeName"` that `ArticleThemesManager` uses, so the two stay in sync.

- [ ] **Step 1: Add keys to the `Key` enum**

In `Yana/Models/AppSettings.swift`, inside `private enum Key`, add:

```swift
        // Reader
        static let readerThemeName = "settings.readerThemeName"
        static let articleTextSize = "settings.articleTextSize"
        static let useSystemBrowser = "settings.useSystemBrowser"
        static let articleFullscreenEnabled = "settings.articleFullscreenEnabled"
```

- [ ] **Step 2: Register defaults**

In the `defaults.register(defaults: [ ... ])` dictionary in `init`, add:

```swift
            Key.articleTextSize: ArticleTextSize.medium.rawValue,
```

(`readerThemeName` defaults via the accessor's `?? ArticleTheme.defaultThemeName`; `useSystemBrowser`/`articleFullscreenEnabled` default to `false` via `defaults.bool`.)

- [ ] **Step 3: Add the accessors**

Add a `// MARK: Reader` section with:

```swift
    // MARK: Reader
    var readerThemeName: String {
        get { access(keyPath: \.readerThemeName); return defaults.string(forKey: Key.readerThemeName) ?? ArticleTheme.defaultThemeName }
        set { withMutation(keyPath: \.readerThemeName) { defaults.set(newValue, forKey: Key.readerThemeName) } }
    }
    var articleTextSize: ArticleTextSize {
        get { access(keyPath: \.articleTextSize); return ArticleTextSize(rawValue: defaults.integer(forKey: Key.articleTextSize)) ?? .medium }
        set { withMutation(keyPath: \.articleTextSize) { defaults.set(newValue.rawValue, forKey: Key.articleTextSize) } }
    }
    var useSystemBrowser: Bool {
        get { access(keyPath: \.useSystemBrowser); return defaults.bool(forKey: Key.useSystemBrowser) }
        set { withMutation(keyPath: \.useSystemBrowser) { defaults.set(newValue, forKey: Key.useSystemBrowser) } }
    }
    var articleFullscreenEnabled: Bool {
        get { access(keyPath: \.articleFullscreenEnabled); return defaults.bool(forKey: Key.articleFullscreenEnabled) }
        set { withMutation(keyPath: \.articleFullscreenEnabled) { defaults.set(newValue, forKey: Key.articleFullscreenEnabled) } }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift
git commit -m "feat(reader): add reader theme/text-size/browser/fullscreen settings"
```

---

## Task 8: ReaderWebViewController (one article)

**Files:**
- Create: `Yana/Reader/ReaderWebViewController.swift`

**Interfaces:**
- Consumes: `ArticleRenderer` (Task 6), `ArticleThemesManager` (Task 5), `AppSettings` (Task 7), `Article`, `ReaderWeb`, `ImageSchemeHandler`.
- Produces:
  - `@MainActor final class ReaderWebViewController: UIViewController` with `let article: Article`, `init(article: Article, allowsFullscreen: Bool, onRefresh: (() -> Void)?, onRequestShowBars: @escaping () -> Void)`.
  - `var scrollView: UIScrollView?` (the web view's scroll view, for the pager's zoom lock).
  - `func reload()` — re-render with the current theme/text size.
  - `func hideBarsTapZonesActive(_:)` — enable/disable the top/bottom 44pt tap zones.
- Behavior: web view pinned to `view` edges; default (automatic) content-inset adjustment; links + `target=_blank` open via `SFSafariViewController` or system browser per `AppSettings.useSystemBrowser`; `yana-img` scheme served by `ImageSchemeHandler`; optional `UIRefreshControl`; observes `ArticleThemesManager.currentThemeDidChange` to re-render.

- [ ] **Step 1: Implement ReaderWebViewController**

```swift
import UIKit
import WebKit
import SafariServices

/// Hosts one article's `WKWebView`, pinned full-screen under the (opaque) bars so WKWebView's
/// automatic content-inset adjustment keeps the article clear of them. Ported/adapted from
/// NetNewsWire's WebViewController, trimmed of Account/extractor/search.
@MainActor
final class ReaderWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    let article: Article
    private let allowsFullscreen: Bool
    private let onRefresh: (() -> Void)?
    private let onRequestShowBars: () -> Void

    private var webView: WKWebView!
    private var loadedHTML: String?

    private var topTapZone: UIView!
    private var bottomTapZone: UIView!

    var scrollView: UIScrollView? { webView?.scrollView }

    private let settings = AppSettings()

    init(article: Article, allowsFullscreen: Bool, onRefresh: (() -> Void)?, onRequestShowBars: @escaping () -> Void) {
        self.article = article
        self.allowsFullscreen = allowsFullscreen
        self.onRefresh = onRefresh
        self.onRequestShowBars = onRequestShowBars
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ReaderWeb.imageScheme)
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if onRefresh != nil {
            let refresh = UIRefreshControl()
            refresh.addTarget(self, action: #selector(handleRefresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }

        configureTapZones()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: ArticleThemesManager.currentThemeDidChange, object: nil
        )
        render()
    }

    func reload() { render() }

    @objc private func themeDidChange() { render() }

    private func render() {
        let html = ArticleRenderer.fullPageHTML(
            article: article,
            theme: ArticleThemesManager.shared.currentTheme,
            textSize: settings.articleTextSize
        )
        guard html != loadedHTML else { return }
        loadedHTML = html
        webView.loadHTMLString(html, baseURL: URL(string: ReaderWeb.baseOrigin))
    }

    @objc private func handleRefresh(_ control: UIRefreshControl) {
        onRefresh?()
        control.endRefreshing()
    }

    // MARK: - Full-screen tap zones

    func hideBarsTapZonesActive(_ active: Bool) {
        topTapZone?.isHidden = !active
        bottomTapZone?.isHidden = !active
    }

    private func configureTapZones() {
        topTapZone = makeTapZone()
        bottomTapZone = makeTapZone()
        NSLayoutConstraint.activate([
            topTapZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topTapZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topTapZone.topAnchor.constraint(equalTo: view.topAnchor),
            topTapZone.heightAnchor.constraint(equalToConstant: 44),
            bottomTapZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomTapZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomTapZone.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomTapZone.heightAnchor.constraint(equalToConstant: 44)
        ])
        topTapZone.isHidden = true
        bottomTapZone.isHidden = true
    }

    private func makeTapZone() -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapZoneTapped)))
        view.addSubview(v)
        return v
    }

    @objc private func tapZoneTapped() { onRequestShowBars() }

    // MARK: - Links → native browser

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            openExternally(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url); return
        }
        if settings.useSystemBrowser {
            UIApplication.shared.open(url)
        } else {
            present(SFSafariViewController(url: url), animated: true)
        }
    }
}
```

- [ ] **Step 2: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Yana/Reader/ReaderWebViewController.swift Yana.xcodeproj
git commit -m "feat(reader): port web view controller (insets, native browser, fullscreen tap-zones)"
```

---

## Task 9: ReaderArticleViewController (pager + chrome + full-screen)

**Files:**
- Create: `Yana/Reader/ReaderArticleViewController.swift`

**Interfaces:**
- Consumes: `ReaderWebViewController` (Task 8), `Article`, `TimelinePageIndex`, `AppSettings`, `ShareSheet` (not needed — uses `UIActivityViewController`).
- Produces:
  - `@MainActor final class ReaderArticleViewController: UIViewController` with public callbacks set by the host:
    - `var onIndexChange: ((Int) -> Void)?`
    - `var onShowFilter: (() -> Void)?`
    - `var onShowSettings: (() -> Void)?`
    - `var onToggleStar: ((Article) -> Void)?`
    - `var onRefresh: (() -> Void)?`
  - `func configure(articles: [Article], index: Int)` and `func update(articles: [Article], index: Int)` (mirrors the old `ArticlePagerView` controller contract).
  - `func setRefreshing(_ isRefreshing: Bool)` — shows/hides the top-left loading indicator.
- Behavior: opaque nav bar (`configureWithDefaultBackground()`); top-left = Filter button + activity indicator (rightmost of the left group); top-right = Settings; bottom `UIToolbar` = Star, Share, Open-in-Browser; `UIPageViewController(.scroll, .horizontal)` paging; tap nav bar / tap zones toggle full-screen (iPhone only), persisted via `AppSettings.articleFullscreenEnabled`.

- [ ] **Step 1: Implement ReaderArticleViewController**

```swift
import UIKit
import SafariServices

/// Pages through the timeline with native opaque nav bar + toolbar and NNW-style tap-to-hide
/// full-screen. Adapted from NetNewsWire's ArticleViewController (no read state / extractor / search).
@MainActor
final class ReaderArticleViewController: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    var onIndexChange: ((Int) -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?
    var onRefresh: (() -> Void)?

    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private var articles: [Article] = []
    private var index = 0
    private var isTransitioning = false

    private let settings = AppSettings()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var starItem: UIBarButtonItem!

    private var isFullscreenAvailable: Bool { traitCollection.userInterfaceIdiom == .phone }
    private var displayedWebVC: ReaderWebViewController? {
        pageController.viewControllers?.first as? ReaderWebViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        configureNavigationItems()
        configureToolbar()

        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        // Tap the nav bar to hide bars (NNW behavior).
        let tapZone = UIView()
        tapZone.translatesAutoresizingMaskIntoConstraints = false
        tapZone.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleFullscreenFromNavBar)))
        NSLayoutConstraint.activate([
            tapZone.widthAnchor.constraint(equalToConstant: 150),
            tapZone.heightAnchor.constraint(equalToConstant: 44)
        ])
        navigationItem.titleView = tapZone
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
        applyFullscreen(settings.articleFullscreenEnabled && isFullscreenAvailable, animated: false)
    }

    // MARK: - Chrome

    private func configureNavigationItems() {
        let filter = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(showFilter)
        )
        filter.accessibilityLabel = String(localized: "Filter articles")
        let indicatorItem = UIBarButtonItem(customView: activityIndicator)
        // Rightmost of the left group = the item added last.
        navigationItem.leftBarButtonItems = [filter, indicatorItem]

        let gear = UIBarButtonItem(
            image: UIImage(systemName: "gear"),
            style: .plain, target: self, action: #selector(showSettings)
        )
        gear.accessibilityLabel = String(localized: "Settings")
        navigationItem.rightBarButtonItem = gear
    }

    private func configureToolbar() {
        starItem = UIBarButtonItem(image: UIImage(systemName: "star"), style: .plain, target: self, action: #selector(toggleStar))
        let share = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareArticle))
        let browser = UIBarButtonItem(image: UIImage(systemName: "safari"), style: .plain, target: self, action: #selector(openInBrowser))
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        toolbarItems = [starItem, flex(), share, flex(), browser]
    }

    func setRefreshing(_ isRefreshing: Bool) {
        if isRefreshing { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
    }

    private func updateStarItem() {
        guard let article = currentArticle() else { return }
        starItem.image = UIImage(systemName: article.isStarred ? "star.fill" : "star")
        starItem.accessibilityLabel = article.isStarred
            ? String(localized: "Unstar article") : String(localized: "Star article")
    }

    // MARK: - Data

    func configure(articles: [Article], index: Int) {
        self.articles = articles
        self.index = clamp(index)
        loadViewIfNeeded()
        if let page = makePage(for: self.index) {
            pageController.setViewControllers([page], direction: .forward, animated: false)
        }
        updateStarItem()
    }

    func update(articles: [Article], index: Int) {
        self.articles = articles
        guard !isTransitioning else { return }
        let target = clamp(index)
        let displayedID = displayedWebVC?.article.identifier
        let targetID = articles.indices.contains(target) ? articles[target].identifier : nil
        self.index = target
        guard displayedID != targetID, let page = makePage(for: target) else {
            updateStarItem(); return
        }
        pageController.setViewControllers([page], direction: .forward, animated: false)
        updateStarItem()
    }

    private func clamp(_ i: Int) -> Int { min(max(i, 0), max(0, articles.count - 1)) }

    private func currentArticle() -> Article? {
        guard articles.indices.contains(index) else { return nil }
        return articles[index]
    }

    private func makePage(for index: Int) -> ReaderWebViewController? {
        guard articles.indices.contains(index) else { return nil }
        let vc = ReaderWebViewController(
            article: articles[index],
            allowsFullscreen: isFullscreenAvailable,
            onRefresh: onRefresh,
            onRequestShowBars: { [weak self] in self?.applyFullscreen(false, animated: true) }
        )
        vc.hideBarsTapZonesActive(settings.articleFullscreenEnabled && isFullscreenAvailable)
        return vc
    }

    // MARK: - Actions

    @objc private func showFilter() { onShowFilter?() }
    @objc private func showSettings() { onShowSettings?() }

    @objc private func toggleStar() {
        guard let article = currentArticle() else { return }
        onToggleStar?(article)
        updateStarItem()
    }

    @objc private func shareArticle() {
        guard let article = currentArticle(), let url = URL(string: article.url) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = toolbarItems?.first
        present(activity, animated: true)
    }

    @objc private func openInBrowser() {
        guard let article = currentArticle(), let url = URL(string: article.url),
              url.scheme == "http" || url.scheme == "https" else { return }
        if settings.useSystemBrowser {
            UIApplication.shared.open(url)
        } else {
            present(SFSafariViewController(url: url), animated: true)
        }
    }

    // MARK: - Full-screen

    @objc private func toggleFullscreenFromNavBar() {
        guard isFullscreenAvailable else { return }
        applyFullscreen(true, animated: true)
    }

    private func applyFullscreen(_ hidden: Bool, animated: Bool) {
        settings.articleFullscreenEnabled = hidden
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        navigationController?.setToolbarHidden(hidden, animated: animated)
        displayedWebVC?.hideBarsTapZonesActive(hidden)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var prefersStatusBarHidden: Bool {
        settings.articleFullscreenEnabled && isFullscreenAvailable
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ReaderWebViewController,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles), i > 0 else { return nil }
        return makePage(for: i - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ReaderWebViewController,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles), i < articles.count - 1 else { return nil }
        return makePage(for: i + 1)
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        isTransitioning = true
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        isTransitioning = false
        guard completed, let vc = displayedWebVC,
              let i = TimelinePageIndex.index(of: vc.article.identifier, in: articles) else { return }
        index = i
        updateStarItem()
        onIndexChange?(i)
    }
}
```

- [ ] **Step 2: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift Yana.xcodeproj
git commit -m "feat(reader): port article view controller (pager, native chrome, fullscreen)"
```

---

## Task 10: ReaderHostView + ReaderScreen, wire into ContentView

**Files:**
- Create: `Yana/Reader/ReaderHostView.swift`
- Modify: `Yana/ContentView.swift`

**Interfaces:**
- Consumes: `ReaderArticleViewController` (Task 9), `AppState`, `AppSettings`, `Article`, `Tag`, `TagFilter`, `TimelineAnchor`, `AggregationService`, `SyncFailureSummary`, existing sheets `ConfigHubView` / `TagFilterView`.
- Produces:
  - `struct ReaderScreen: View` (owns `@Query`, position-memory, refresh, sheets) — used by `ContentView`.
  - `struct ReaderHostView: UIViewControllerRepresentable` with `articles: [Article]`, `currentIndex: Binding<Int>`, `isRefreshing: Bool`, `onRefresh`, `onShowFilter`, `onShowSettings`, `onToggleStar`.

- [ ] **Step 1: Implement ReaderHostView.swift**

```swift
import SwiftData
import SwiftUI

/// Bridges the UIKit reader into SwiftUI: feeds the filtered timeline + selected index down to
/// `ReaderArticleViewController` and reports index changes back up. The chrome buttons call back
/// into SwiftUI for the Filter/Settings sheets and starring.
struct ReaderHostView: UIViewControllerRepresentable {
    let articles: [Article]
    @Binding var currentIndex: Int
    let isRefreshing: Bool
    var onRefresh: (() -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?

    func makeUIViewController(context: Context) -> UINavigationController {
        let reader = ReaderArticleViewController()
        context.coordinator.reader = reader
        reader.onIndexChange = { currentIndex = $0 }
        reader.onShowFilter = onShowFilter
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.configure(articles: articles, index: currentIndex)
        reader.setRefreshing(isRefreshing)

        let nav = UINavigationController(rootViewController: reader)
        nav.isToolbarHidden = false
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        guard let reader = context.coordinator.reader else { return }
        reader.onIndexChange = { currentIndex = $0 }
        reader.onShowFilter = onShowFilter
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.update(articles: articles, index: currentIndex)
        reader.setRefreshing(isRefreshing)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var reader: ReaderArticleViewController?
    }
}

/// The home surface: owns the timeline `@Query`, tag filter, position memory, refresh, and the
/// Settings/Filter sheets. Replaces the former `ArticleReaderView`.
struct ReaderScreen: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var didRestoreAnchor = false
    @State private var isRefreshing = false

    private var filteredArticles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    var body: some View {
        let articles = filteredArticles
        Group {
            if articles.isEmpty {
                ContentUnavailableView {
                    Label("No Articles", systemImage: "tray")
                        .accessibilityIdentifier("emptyArticlesTitle")
                } description: {
                    Text("Add feeds in Configuration, then pull down to refresh.")
                } actions: {
                    Button(String(localized: "Add Your First Feed")) { appState.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ReaderHostView(
                    articles: articles,
                    currentIndex: $appState.currentIndex,
                    isRefreshing: isRefreshing,
                    onRefresh: triggerRefresh,
                    onShowFilter: { appState.showFilter = true },
                    onShowSettings: { appState.showSettings = true },
                    onToggleStar: toggleStar
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
        .sheet(isPresented: $appState.showFilter, onDismiss: clampIndex) { TagFilterView() }
        .alert("Update Failed", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onAppear { restoreAnchor() }
        .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
        .onChange(of: allArticles) { _, _ in
            if didRestoreAnchor { clampIndex() } else { restoreAnchor() }
        }
    }

    private func toggleStar(_ article: Article) {
        guard let starredTag else { return }
        article.setStarred(!article.isStarred, using: starredTag)
        try? modelContext.save()
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        let articles = filteredArticles
        guard !articles.isEmpty, !didRestoreAnchor else { return }
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
        didRestoreAnchor = true
    }

    private func saveAnchor() {
        let articles = filteredArticles
        guard !articles.isEmpty else { return }
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return }
        settings.timelineAnchorIdentifier = articles[appState.currentIndex].identifier
    }

    private func clampIndex() {
        appState.currentIndex = min(appState.currentIndex, max(0, filteredArticles.count - 1))
    }

    // MARK: - Refresh

    private func triggerRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let service = AggregationService(context: modelContext)
            await service.updateAll()
            appState.errorMessage = SyncFailureSummary.message(for: service.lastRunFailures)
            isRefreshing = false
        }
    }
}
```

- [ ] **Step 2: Point ContentView at ReaderScreen**

Replace the body of `Yana/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        ReaderScreen(appState: appState)
    }
}
```

- [ ] **Step 3: Move ShareSheet (still referenced elsewhere) out of the deleted file**

`ShareSheet` currently lives in `ArticleReaderView.swift` (deleted in Task 12). Add it to the bottom of `Yana/Reader/ReaderHostView.swift`:

```swift
import UIKit

/// Presents a `UIActivityViewController` from SwiftUI (used by the search detail + link sheets).
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 4: Generate + build (old files still present; expect duplicate-symbol or success)**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -6`
Expected: a build error about `ShareSheet` redeclared (it still exists in `ArticleReaderView.swift`). That's expected — Task 12 deletes the old files. If you prefer a clean green build here, do Task 12 before this step's build. Either way, do not commit a non-building state: proceed straight to Task 11/12, then build green.

- [ ] **Step 5: Commit (code only; build verified green after Task 12)**

```bash
git add Yana/Reader/ReaderHostView.swift Yana/ContentView.swift Yana.xcodeproj
git commit -m "feat(reader): add ReaderScreen + ReaderHostView and host them in ContentView"
```

---

## Task 11: Switch ArticleDetailView to the ported renderer

**Files:**
- Modify: `Yana/Views/ArticleDetailView.swift`

**Interfaces:**
- Consumes: `ReaderWebViewController` (Task 8).
- Produces: a `ReaderDetailWebView: UIViewControllerRepresentable` wrapping `ReaderWebViewController(article:allowsFullscreen:false,onRefresh:nil,onRequestShowBars:{})` so the config-hub search detail renders with the same themed HTML and native-browser links, but no paging/full-screen and standard insets (it lives inside a `NavigationStack` with a normal bar).

- [ ] **Step 1: Read the current ArticleDetailView**

Run: `cat Yana/Views/ArticleDetailView.swift`
Expected: it currently calls `ArticleContentView(article: article)`.

- [ ] **Step 2: Replace ArticleContentView usage**

Rewrite `Yana/Views/ArticleDetailView.swift` to use a representable around `ReaderWebViewController`. Preserve the existing navigation title / toolbar that wraps it (keep whatever surrounding chrome the current file has; only swap the content view). The content becomes:

```swift
import SwiftUI

struct ArticleDetailView: View {
    let article: Article

    var body: some View {
        ReaderDetailWebView(article: article)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(article.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The config-hub search detail: the same themed article web view as the reader, but with no
/// paging, no full-screen, and standard insets (it sits inside a normal navigation bar).
private struct ReaderDetailWebView: UIViewControllerRepresentable {
    let article: Article

    func makeUIViewController(context: Context) -> ReaderWebViewController {
        ReaderWebViewController(article: article, allowsFullscreen: false, onRefresh: nil, onRequestShowBars: {})
    }

    func updateUIViewController(_ uiViewController: ReaderWebViewController, context: Context) {}
}
```

> If the current `ArticleDetailView` has additional toolbar items (share/open), keep them — only the body content view changes from `ArticleContentView` to `ReaderDetailWebView`. Confirm against the Step-1 output and preserve existing behavior.

- [ ] **Step 3: Build (after Task 12 removes old files)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (once Task 12 is also applied).

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/ArticleDetailView.swift
git commit -m "feat(reader): render search detail with the ported themed web view"
```

---

## Task 12: Remove the old SwiftUI reader stack

**Files:**
- Remove: `Yana/Views/ArticleReaderView.swift`, `Yana/Views/ArticlePagerView.swift`, `Yana/Views/ArticleContentView.swift`, `Yana/Views/ArticleWebView.swift`, `Yana/Views/LinkWebView.swift`

**Interfaces:**
- Consumes/Produces: nothing new. Removes `ArticleReaderView`, `ArticlePagerView`/`ArticlePagerController`/`ArticlePage`, `ArticleContentView`, `ArticleWebView`, `IdentifiedURL`/`LinkWebView`/`LinkSheet`, and the old `ShareSheet` (re-added in Task 10). Verify nothing else references these.

- [ ] **Step 1: Confirm no remaining references**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
grep -rn "ArticleReaderView\|ArticlePagerView\|ArticleContentView\|ArticleWebView\|LinkWebView\|LinkSheet\|IdentifiedURL" Yana --include=*.swift | grep -v "Yana/Views/ArticleReaderView.swift\|Yana/Views/ArticlePagerView.swift\|Yana/Views/ArticleContentView.swift\|Yana/Views/ArticleWebView.swift\|Yana/Views/LinkWebView.swift"
```
Expected: no output (the only matches are inside the files being deleted). If any other file references them, update it (the reader entry point is now `ReaderScreen`).

- [ ] **Step 2: Delete the files**

```bash
git rm Yana/Views/ArticleReaderView.swift Yana/Views/ArticlePagerView.swift Yana/Views/ArticleContentView.swift Yana/Views/ArticleWebView.swift Yana/Views/LinkWebView.swift
```

- [ ] **Step 3: Generate + build green**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -4`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -8`
Expected: all tests pass (MacroProcessor, ArticleRenderer, ArticleThemesManager, plus pre-existing).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(reader): remove the old SwiftUI reader stack"
```

---

## Task 13: Reader settings section

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift`

**Interfaces:**
- Consumes: `AppSettings` (Task 7), `ArticleThemesManager` (Task 5), `ArticleTextSize` (Task 2).
- Produces: a **Reader** `Section` with a theme `Picker` (over `ArticleThemesManager.shared.themeNames`, bound so selection sets both `settings.readerThemeName` and `ArticleThemesManager.shared.currentThemeName`), an article-text-size `Picker` (over `ArticleTextSize.allCases`), and a **Use system browser** `Toggle` (`settings.useSystemBrowser`).

- [ ] **Step 1: Inspect SettingsScreenView structure**

Run: `sed -n '1,60p' Yana/Views/Config/SettingsScreenView.swift`
Expected: a `Form`/`List` with `Section`s and an `@State private var settings = AppSettings()` (or similar). Match the file's existing style for the new section.

- [ ] **Step 2: Add the Reader section**

Insert a new `Section` (place it near the top of the form, before AI/source sections). Use the file's existing `settings` instance:

```swift
            Section(String(localized: "Reader")) {
                Picker(String(localized: "Theme"), selection: Binding(
                    get: { settings.readerThemeName },
                    set: { newValue in
                        settings.readerThemeName = newValue
                        ArticleThemesManager.shared.currentThemeName = newValue
                    }
                )) {
                    ForEach(ArticleThemesManager.shared.themeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                Picker(String(localized: "Text Size"), selection: Binding(
                    get: { settings.articleTextSize },
                    set: { settings.articleTextSize = $0 }
                )) {
                    ForEach(ArticleTextSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }

                Toggle(String(localized: "Use System Browser"), isOn: Binding(
                    get: { settings.useSystemBrowser },
                    set: { settings.useSystemBrowser = $0 }
                ))
            }
```

- [ ] **Step 3: Add the 3 new strings to the catalog**

Add to `Localizable.xcstrings` (with `de`, `translated`): `Reader`→`Reader`, `Theme`→`Design`, `Text Size`→`Textgröße`, `Use System Browser`→`Systembrowser verwenden`.

- [ ] **Step 4: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(reader): add Reader settings (theme, text size, system browser)"
```

---

## Task 14: Theme change live-refresh + manual verification

**Files:**
- Modify (if needed): `Yana/Reader/ReaderArticleViewController.swift` (re-render visible page on theme/text-size change)

**Interfaces:**
- Consumes: `ArticleThemesManager.currentThemeDidChange` (Task 5) — already observed per-page in `ReaderWebViewController` (Task 8). Text-size changes are not broadcast, so handle them here.

- [ ] **Step 1: Re-render visible page after Settings closes**

`ReaderWebViewController` already re-renders on `currentThemeDidChange`. Text-size changes have no notification, so reload the displayed page when the reader reappears (after the Settings sheet dismisses). In `ReaderArticleViewController.viewWillAppear`, after the fullscreen line, add:

```swift
        displayedWebVC?.reload()
```

(`reload()` is a no-op when the rendered HTML is unchanged, so this is cheap.)

- [ ] **Step 2: Generate + build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual verification in the simulator**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build` then launch in the simulator. Verify:
  1. On load, the article **title is fully below** the opaque nav bar (not clipped behind it).
  2. The bottom toolbar sits flush at the bottom safe area (not floating high).
  3. Tapping the nav bar (or the top/bottom tap zones) **hides** the nav bar + toolbar + status bar; tapping a zone again restores them; the hidden state persists when swiping to the next article.
  4. Tapping a link in the article opens **SFSafariViewController** (default) or the system browser when "Use System Browser" is on.
  5. Star toggles the star icon; Share presents the share sheet; Open-in-Browser opens the page.
  6. Switching theme in Settings re-renders the visible article; changing Text Size and returning re-renders it.
  7. Pull-to-refresh on the article triggers a timeline refresh and the **top-left** loading indicator appears (rightmost of the left group, beside Filter).

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift Yana.xcodeproj
git commit -m "feat(reader): reload visible article after text-size/theme changes"
```

---

## Task 15: Docs sync

**Files:**
- Modify: `CLAUDE.md` (Views section: reader is now the UIKit port under `Yana/Reader/`; themes under `Yana/Resources/Themes/`)

**Interfaces:** none.

- [ ] **Step 1: Update CLAUDE.md architecture notes**

In `CLAUDE.md`, update the **Views** bullet and add a short **Reader** note describing: the reader is a UIKit port of NetNewsWire (`Yana/Reader/`: `ReaderArticleViewController`, `ReaderWebViewController`, `ReaderHostView`/`ReaderScreen`), rendering via `ArticleRenderer` + `MacroProcessor` + the bundled `.nnwtheme` theme system (`ArticleThemesManager`), with full-screen reading, native-browser links, and a Reader settings section (theme / text size / system browser). Remove references to the deleted `ArticleReaderView`/`ArticleContentView`.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe the ported NetNewsWire reader and theme system"
```

---

## Self-Review Notes

- **Spec coverage:** §1 hosting → Tasks 9,10. §2 chrome/full-screen → Tasks 8,9,14. §3 rendering/themes → Tasks 1–6. §4 native browser → Tasks 8,9. §5 settings → Tasks 7,13. §6 removals/ArticleDetailView → Tasks 11,12. §7 localization → Tasks 2,4,13; tests → Tasks 1,5,6. Refresh indicator top-left adjustment → Task 9 Step 1 + Task 14 Step 3.7.
- **Type consistency:** `ReaderWebViewController.init(article:allowsFullscreen:onRefresh:onRequestShowBars:)`, `.reload()`, `.hideBarsTapZonesActive(_:)`, `.scrollView` used consistently in Tasks 8/9/11. `ReaderArticleViewController.configure/update/setRefreshing` + `onIndexChange/onShowFilter/onShowSettings/onToggleStar/onRefresh` used consistently in Task 10. `ArticleRenderer.fullPageHTML`/`articleHTML`, `ArticleThemesManager.shared.{themeNames,currentThemeName,currentTheme,currentThemeDidChange}`, `ArticleTextSize.cssClass`/`displayName`/`allCases` consistent across tasks.
- **Ordering caveat (documented in-task):** Tasks 10 and 11 only build green after Task 12 deletes the old files (old `ShareSheet` collision). Execute 10 → 11 → 12 before expecting a green build; this is called out in Task 10 Step 4 and Task 11 Step 3.
- **Resource-layout risk:** Task 3 Step 5 verifies the `.nnwtheme` bundle layout; Task 5 Step 3 notes the `subdirectory:` adjustment if themes land under `Themes/`.
