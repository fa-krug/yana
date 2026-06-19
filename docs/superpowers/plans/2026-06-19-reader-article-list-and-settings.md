# Reader Article List + Settings Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-left article-list button to the reader that mirrors the reader's filter and selection, move the filter to the right toolbar, fold Settings into the overflow menu, and restructure the old Library hub into a direct Settings page that links Feeds/Tags.

**Architecture:** The reader (`ReaderScreen`) stays the single owner of the timeline `@Query`, the shared `AppSettings` filter, and the selected index. A repurposed `ArticleListView` is presented as a sheet that reads the same filter and reports a tapped article back up; the reader resolves it to an index by identifier and jumps. Settings opens directly (the `ConfigHubView` hub is deleted) and gains a top Feeds/Tags section.

**Tech Stack:** SwiftUI, SwiftData (`@Query`/`@Model`), UIKit (`ReaderArticleViewController` / `UIPageViewController`), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` throughout (all tests use `@MainActor`).
- Platform iOS 26.0+ (iPhone and iPad).
- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- After creating or deleting any `.swift` file, run `xcodegen generate` before building (sources are folder-globbed from `project.yml`).
- ALWAYS localize: every new/changed user-facing string needs a `de` entry in `Yana/Resources/Localizable.xcstrings` marked `"state": "translated"`. German uses Apple style (infinitive, no Du/Sie). Remove strings orphaned by deletions.

---

## File Structure

- `Yana/Reader/ReaderMenuBuilder.swift` — drop `showGoToFeed`; `config` loses its `hasFeed` param.
- `Yana/Reader/ReaderArticleViewController.swift` — chrome: add article-list button (left), move filter to right group, add Settings menu action, remove Go-to-feed action + `onGoToFeed`.
- `Yana/Reader/ReaderHostView.swift` — `ReaderHostView` (representable) gains `onShowArticleList`, drops `onGoToFeed`; `ReaderScreen` presents the list + Settings sheets, adds `openArticle`, drops `goToFeed`/`feedToEdit` sheet.
- `Yana/Models/AppState.swift` — add `showArticleList`, remove `feedToEdit`.
- `Yana/Views/Config/ManagedList.swift` — add optional `scrollToID` (scroll to a row on appear).
- `Yana/Views/Config/ArticleListView.swift` — repurposed: shared `AppSettings` filter, `TagFilterView`, tap→`onSelect`, highlight + auto-scroll to `currentArticleID`.
- `Yana/Views/Config/SettingsScreenView.swift` — top Feeds/Tags section + close button.
- `Yana/Views/Config/ConfigHubView.swift` — **deleted**.
- `Yana/Views/ArticleDetailView.swift` — **deleted** (only the old list tapped it).
- `Yana/Views/Config/ArticleTagFilterView.swift` — **deleted** (only the old list used it).
- `Yana/Resources/Localizable.xcstrings` — add "Article list"; remove orphaned strings.
- `YanaTests/ReaderMenuBuilderTests.swift` — drop Go-to-feed assertions.
- `YanaTests/ArticleListFilterTests.swift` — **new**: shared pipeline + identifier jump resolution.

---

## Task 1: Remove "Go to feed" end-to-end

**Files:**
- Modify: `Yana/Reader/ReaderMenuBuilder.swift`
- Modify: `Yana/Reader/ReaderArticleViewController.swift` (`onGoToFeed` prop ~line 18; menu branch lines 231-236; config call line 205-207)
- Modify: `Yana/Reader/ReaderHostView.swift` (`onGoToFeed` lines 20, 37, 60, 146; `goToFeed` 217-219; `feedToEdit` sheet 156-158)
- Modify: `Yana/Models/AppState.swift` (line 13)
- Test: `YanaTests/ReaderMenuBuilderTests.swift`

**Interfaces:**
- Produces: `ReaderMenuConfig(showCopyLink: Bool, showSummarize: Bool)`; `ReaderMenuBuilder.config(hasURL: Bool, aiReady: Bool) -> ReaderMenuConfig`.

- [ ] **Step 1: Update the test to the new config shape**

Replace the body of `YanaTests/ReaderMenuBuilderTests.swift` with:

```swift
import Testing
@testable import Yana

@Suite("ReaderMenuBuilder")
struct ReaderMenuBuilderTests {
    @Test func allVisibleWhenEverythingPresent() {
        let c = ReaderMenuBuilder.config(hasURL: true, aiReady: true)
        #expect(c == ReaderMenuConfig(showCopyLink: true, showSummarize: true))
    }

    @Test func copyLinkHiddenWithoutURL() {
        #expect(ReaderMenuBuilder.config(hasURL: false, aiReady: true).showCopyLink == false)
    }

    @Test func summarizeHiddenWhenAINotReady() {
        #expect(ReaderMenuBuilder.config(hasURL: true, aiReady: false).showSummarize == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderMenuBuilderTests 2>&1 | tail -20`
Expected: build failure — `extra argument 'hasFeed'` / `showGoToFeed` no longer referenced is not yet true (source still has it), so the compile fails on the test's removed `hasFeed`/`showGoToFeed`.

- [ ] **Step 3: Trim `ReaderMenuBuilder`**

Replace `Yana/Reader/ReaderMenuBuilder.swift` with:

```swift
import Foundation

/// Which conditional items the reader's overflow menu should show for the current article.
/// Force update is unconditional and not represented here.
struct ReaderMenuConfig: Equatable {
    var showCopyLink: Bool
    var showSummarize: Bool
}

enum ReaderMenuBuilder {
    static func config(hasURL: Bool, aiReady: Bool) -> ReaderMenuConfig {
        ReaderMenuConfig(showCopyLink: hasURL, showSummarize: aiReady)
    }
}
```

- [ ] **Step 4: Remove the Go-to-feed action + property in the view controller**

In `Yana/Reader/ReaderArticleViewController.swift`:

Delete the property declaration:
```swift
    var onGoToFeed: ((Feed) -> Void)?
```

Update the config call in `buildMenuActions()` (was lines 205-207):
```swift
        let config = ReaderMenuBuilder.config(
            hasURL: !article.url.isEmpty, aiReady: aiReady
        )
```

Delete the entire Go-to-feed block (was lines 231-236):
```swift
        if config.showGoToFeed, let feed = article.feed {
            actions.append(UIAction(
                title: String(localized: "Go to feed"),
                image: UIImage(systemName: "dot.radiowaves.up.forward")
            ) { [weak self] _ in self?.onGoToFeed?(feed) })
        }
```

- [ ] **Step 5: Remove the Go-to-feed plumbing in the host + screen**

In `Yana/Reader/ReaderHostView.swift`:

Delete the `ReaderHostView` property `var onGoToFeed: ((Feed) -> Void)?` (line 20) and both assignments `reader.onGoToFeed = onGoToFeed` (lines 37 and 60).

Delete the argument `onGoToFeed: goToFeed,` from the `ReaderHostView(...)` call (line 146).

Delete the feed-editor sheet (lines 156-158):
```swift
        .sheet(item: $appState.feedToEdit) { feed in
            NavigationStack { FeedEditorView(feed: feed) }
        }
```

Delete the handler (lines 217-219):
```swift
    private func goToFeed(_ feed: Feed) {
        appState.feedToEdit = feed
    }
```

- [ ] **Step 6: Remove `feedToEdit` from `AppState`**

In `Yana/Models/AppState.swift` delete:
```swift
    /// When non-nil, the reader presents `FeedEditorView` for this feed as a sheet.
    var feedToEdit: Feed?
```

- [ ] **Step 7: Remove the orphaned localized string**

In `Yana/Resources/Localizable.xcstrings`, delete the entire `"Go to feed": { ... }` entry (the key, its localizations block, and trailing comma).

- [ ] **Step 8: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderMenuBuilderTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (3 tests pass).

- [ ] **Step 9: Commit**

```bash
git add Yana/Reader/ReaderMenuBuilder.swift Yana/Reader/ReaderArticleViewController.swift Yana/Reader/ReaderHostView.swift Yana/Models/AppState.swift Yana/Resources/Localizable.xcstrings YanaTests/ReaderMenuBuilderTests.swift
git commit -m "feat(reader): remove Go to feed action and its plumbing"
```

---

## Task 2: Reader chrome — article-list button (left), filter to right, Settings into menu

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift` (chrome: `configureNavigationItems`, `setRefreshing`, `buildMenuActions`, new action/property)
- Modify: `Yana/Reader/ReaderHostView.swift` (`ReaderHostView` add `onShowArticleList`; `ReaderScreen` wire it)
- Modify: `Yana/Models/AppState.swift` (add `showArticleList`)
- Modify: `Yana/Resources/Localizable.xcstrings` (add "Article list")

**Interfaces:**
- Consumes: `ReaderMenuConfig`/`config(hasURL:aiReady:)` from Task 1.
- Produces: `ReaderArticleViewController.onShowArticleList: (() -> Void)?`; `AppState.showArticleList: Bool`.

- [ ] **Step 1: Add `showArticleList` to `AppState`**

In `Yana/Models/AppState.swift`, add next to the other sheet flags:
```swift
    var showArticleList = false
```

- [ ] **Step 2: Add the article-list button + property + Settings menu action in the view controller**

In `Yana/Reader/ReaderArticleViewController.swift`:

Add the callback near the other `var on...` callbacks (after `onShowFilter`):
```swift
    var onShowArticleList: (() -> Void)?
```

Add a stored bar-button item alongside `filterItem` (near line 31-35):
```swift
    private var articleListItem: UIBarButtonItem!
```

Replace `configureNavigationItems()` (lines 83-116) with:

```swift
    private func configureNavigationItems() {
        articleListItem = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            style: .plain, target: self, action: #selector(showArticleList)
        )
        articleListItem.accessibilityLabel = String(localized: "Article list")

        filterItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(showFilter)
        )
        filterItem.accessibilityLabel = String(localized: "Filter articles")
        // The loading indicator only joins the left group while a refresh runs (see
        // setRefreshing). A stopped indicator's bar-button item still reserves width, so it is
        // added/removed rather than left in place hidden.
        indicatorItem = UIBarButtonItem(customView: activityIndicator)
        navigationItem.leftBarButtonItems = [articleListItem]

        starItem = UIBarButtonItem(image: UIImage(systemName: "star"), style: .plain, target: self, action: #selector(toggleStar))

        // Overflow menu, rebuilt each time it opens so conditional items track the current
        // article + AI state. UIDeferredMenuElement.uncached re-invokes the provider per present.
        menuItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.buildMenuActions() ?? [])
                }
            ])
        )
        menuItem.accessibilityLabel = String(localized: "More actions")
        // rightBarButtonItems is ordered edge-inward: [menu, filter, star] puts the overflow
        // menu at the screen edge, then the filter, then the star (on-screen L→R: star, filter, menu).
        navigationItem.rightBarButtonItems = [menuItem, filterItem, starItem]
    }
```

(Note: the old `library` local button is removed entirely.)

Replace `setRefreshing(_:)` (lines 126-132) with:
```swift
    func setRefreshing(_ isRefreshing: Bool) {
        if isRefreshing { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        let items: [UIBarButtonItem] = isRefreshing ? [articleListItem, indicatorItem] : [articleListItem]
        if navigationItem.leftBarButtonItems?.count != items.count {
            navigationItem.leftBarButtonItems = items
        }
    }
```

Add the action next to `@objc private func showFilter()` (line 194):
```swift
    @objc private func showArticleList() { onShowArticleList?() }
```

In `buildMenuActions()`, append a Settings section as the last element, immediately before `return actions`:
```swift
        let settings = UIAction(
            title: String(localized: "Settings"),
            image: UIImage(systemName: "gearshape")
        ) { [weak self] _ in self?.onShowSettings?() }
        actions.append(UIMenu(title: "", options: .displayInline, children: [settings]))

        return actions
```

- [ ] **Step 3: Wire `onShowArticleList` through `ReaderHostView`**

In `Yana/Reader/ReaderHostView.swift`, add the property to `ReaderHostView` (after `onShowFilter`):
```swift
    var onShowArticleList: (() -> Void)?
```

In `makeUIViewController` (after `reader.onShowFilter = onShowFilter`) and in `updateUIViewController` (after `reader.onShowFilter = onShowFilter`), add:
```swift
        reader.onShowArticleList = onShowArticleList
```

- [ ] **Step 4: Pass it from `ReaderScreen`**

In `Yana/Reader/ReaderHostView.swift`, in the `ReaderHostView(...)` call inside `ReaderScreen.body`, add after `onShowFilter:`:
```swift
                    onShowArticleList: { appState.showArticleList = true },
```
(The list sheet that consumes `appState.showArticleList` is added in Task 5; the button compiles and is inert until then.)

- [ ] **Step 5: Add the "Article list" localized string**

In `Yana/Resources/Localizable.xcstrings`, add a new entry (keys are alphabetical; place near other "A" keys):
```json
    "Article list" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Artikelliste"
          }
        }
      }
    },
```

- [ ] **Step 6: Build to verify chrome compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. Manual check (Xcode): reader left edge shows the list button; right edge reads star · filter · ⋯; the ⋯ menu has a Settings item; no more `books.vertical` button.

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift Yana/Reader/ReaderHostView.swift Yana/Models/AppState.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(reader): article-list button, filter on right, Settings in overflow menu"
```

---

## Task 3: `ManagedList` scroll-to-row support

**Files:**
- Modify: `Yana/Views/Config/ManagedList.swift`

**Interfaces:**
- Produces: `ManagedList` gains `var scrollToID: Item.ID? = nil`; when set, scrolls to that row on appear.

- [ ] **Step 1: Add `scrollToID` and wrap the List in a `ScrollViewReader`**

In `Yana/Views/Config/ManagedList.swift`, add the property after `var onMove` (line 22):
```swift
    /// When set, the list scrolls this row into view once on appear (used to reveal the
    /// reader's currently-selected article). Existing callers omit it (defaults to nil).
    var scrollToID: Item.ID? = nil
```

Replace the `body` (lines 31-53) with:
```swift
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    row(item)
                        .swipeActions(edge: .leading) {
                            leadingActions(item)
                        }
                }
                .onDelete(perform: onDelete)
                .onMove(perform: reorderEnabled ? onMove : nil)
            }
            .searchable(text: $searchText, prompt: searchPrompt)
            .overlay {
                if items.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: emptyIcon,
                                               description: Text(emptyDescription))
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .onAppear {
                if let scrollToID {
                    proxy.scrollTo(scrollToID, anchor: .center)
                }
            }
        }
    }
```

(The convenience `init` in the extension needs no change — `scrollToID` has a default value.)

- [ ] **Step 2: Build to verify existing callers still compile**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **` (Feeds/Tags/Articles lists unchanged).

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/ManagedList.swift
git commit -m "feat(list): optional scroll-to-row on appear in ManagedList"
```

---

## Task 4: Settings opens directly; add Feeds/Tags section; delete the hub

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (settings sheet in `ReaderScreen`)
- Delete: `Yana/Views/Config/ConfigHubView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings` (add section footer; remove hub-only strings)

**Interfaces:**
- Consumes: `FeedsView`, `TagsView` (existing).
- Produces: `SettingsScreenView` is now a self-contained sheet root (own close button + Feeds/Tags links).

- [ ] **Step 1: Point the reader's settings sheet at `SettingsScreenView`**

In `Yana/Reader/ReaderHostView.swift`, replace:
```swift
        .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
```
with:
```swift
        .sheet(isPresented: $appState.showSettings) { NavigationStack { SettingsScreenView() } }
```

- [ ] **Step 2: Add a close button + Feeds/Tags section to `SettingsScreenView`**

In `Yana/Views/Config/SettingsScreenView.swift`, add the dismiss environment after the existing `@State` declarations (near line 16):
```swift
    @Environment(\.dismiss) private var dismiss
```

Replace the `Form { ... }` block and its `.navigationTitle` (lines 40-49) with:
```swift
        Form {
            organizeSection
            readerSection
            redditSection
            youtubeSection
            notificationsSection
            aiProviderSection
            aiKnobsSection
            librarySection
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
        }
```

Add the new section just before `readerSection` (before line 60):
```swift
    // MARK: Organize

    private var organizeSection: some View {
        Section {
            NavigationLink {
                FeedsView()
            } label: {
                Label("Feeds", systemImage: "list.bullet.rectangle")
                    .labelStyle(.tintedIcon(.orange))
            }
            NavigationLink {
                TagsView()
            } label: {
                Label("Tags", systemImage: "tag")
                    .labelStyle(.tintedIcon(.pink))
            }
        } footer: {
            Text("Manage your feeds and the tags applied to articles.")
        }
    }
```

- [ ] **Step 3: Delete the hub and its now-orphaned strings**

```bash
git rm Yana/Views/Config/ConfigHubView.swift
```

In `Yana/Resources/Localizable.xcstrings`, delete these entries that only `ConfigHubView` used:
- `"Organize your sources and browse everything you've collected."`
- `"Sources, AI, notifications, and library preferences."`

Add the new footer string:
```json
    "Manage your feeds and the tags applied to articles." : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Feeds und die auf Artikel angewendeten Tags verwalten."
          }
        }
      }
    },
```

- [ ] **Step 4: Regenerate and build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. Manual check: ⋯ → Settings opens the settings screen with Feeds/Tags at the top and an `xmark` close button. (`ArticleListView` is now referenced by nothing — it is repurposed in Task 5.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(settings): open Settings directly with Feeds/Tags section; delete Library hub"
```

---

## Task 5: Repurpose `ArticleListView` into the shared jump list + present from reader

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift` (full rewrite of behavior)
- Modify: `Yana/Reader/ReaderHostView.swift` (`ReaderScreen`: list sheet + `openArticle`)
- Test: `YanaTests/ArticleListFilterTests.swift` (new)

**Interfaces:**
- Consumes: `AppState.showArticleList` (Task 2); `ManagedList.scrollToID` (Task 3); `TagFilterView` (existing); `ArticleSearch.filter(_:query:)`, `TagFilter.apply(to:disabledTagNames:includeUntagged:)`, `FeedFilter.apply(to:disabledFeedNames:)`, `TimelinePageIndex.index(of:in:)` (existing).
- Produces: `ArticleListView(currentArticleID: String?, onSelect: (Article) -> Void)`.

- [ ] **Step 1: Write the failing test for the shared pipeline + jump resolution**

Create `YanaTests/ArticleListFilterTests.swift`:

```swift
import Testing
import SwiftData
@testable import Yana

@MainActor
@Suite("ArticleListFilter")
struct ArticleListFilterTests {
    /// Mirrors ArticleListView.results: search → TagFilter → FeedFilter, using the same
    /// AppSettings-backed filter values the reader uses. The list's results must be a subset
    /// of the reader's filtered timeline so a tapped article always resolves to an index.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Article.self, Feed.self, Tag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func listResultsAreSubsetAndJumpResolves() throws {
        let ctx = try makeContext()
        let feedA = Feed(name: "Alpha", aggregatorType: .feedContent, identifier: "a")
        let feedB = Feed(name: "Beta", aggregatorType: .feedContent, identifier: "b")
        ctx.insert(feedA); ctx.insert(feedB)
        let a1 = Article(title: "Alpha one", identifier: "a1", url: "https://a/1")
        let a2 = Article(title: "Beta two", identifier: "b2", url: "https://b/2")
        ctx.insert(a1); ctx.insert(a2)
        a1.feed = feedA
        a2.feed = feedB
        let all = [a1, a2]

        // Reader filter: disable feed "Beta".
        let disabledFeeds: Set<String> = ["Beta"]

        // Reader's filtered timeline (no search).
        let readerFiltered = FeedFilter.apply(
            to: TagFilter.apply(to: all, disabledTagNames: [], includeUntagged: true),
            disabledFeedNames: disabledFeeds
        )
        // List results (same filter + a matching search).
        let listResults = FeedFilter.apply(
            to: TagFilter.apply(
                to: ArticleSearch.filter(all, query: "Alpha"),
                disabledTagNames: [], includeUntagged: true),
            disabledFeedNames: disabledFeeds
        )

        #expect(readerFiltered.map(\.identifier) == ["a1"])
        #expect(listResults.map(\.identifier) == ["a1"])
        // A tapped list article resolves to an index in the reader's filtered timeline.
        #expect(TimelinePageIndex.index(of: "a1", in: readerFiltered) == 0)
        // An article filtered out of the reader's timeline resolves to nil (no jump).
        #expect(TimelinePageIndex.index(of: "b2", in: readerFiltered) == nil)
    }
}
```

- [ ] **Step 2: Run the test to confirm it builds against existing helpers**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleListFilterTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. (If `Article`/`Feed` initializer labels differ from the snippet, adjust the test to the real initializers — check `Yana/Models/Article.swift` and `Feed.swift` — then re-run until green. This step pins the shared-pipeline contract the rewrite must honor.)

- [ ] **Step 3: Rewrite `ArticleListView`**

Replace the entire contents of `Yana/Views/Config/ArticleListView.swift` with:

```swift
import SwiftData
import SwiftUI

/// A second view of the reader's timeline: the same articles under the same shared `AppSettings`
/// filter, plus an in-memory search. Tapping a row reports the article via `onSelect` so the
/// reader can jump to it; the row matching `currentArticleID` is highlighted and scrolled into
/// view on appear. Keeps swipe actions (star/reload) and swipe-to-delete.
struct ArticleListView: View {
    let currentArticleID: String?
    let onSelect: (Article) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(ArticleListView.timelineDescriptor) private var allArticles: [Article]

    static var timelineDescriptor: FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return descriptor
    }
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var showFilter = false
    @State private var articleToDelete: Article?

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    /// Shared, app-lifetime flag so the spinner survives leaving and returning to this screen.
    private var isUpdating: Bool { UpdateActivity.shared.isUpdating }

    /// Same pipeline as `ReaderScreen.recomputeFilter` (TagFilter → FeedFilter over the shared
    /// `AppSettings` filter) plus the search layer, so results are a subset of the reader timeline.
    private var results: [Article] {
        let searched = ArticleSearch.filter(allArticles, query: debouncedSearch)
        let byTag = TagFilter.apply(to: searched,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        return FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    private var isFilterActive: Bool { settings.isTimelineFilterActive }

    /// Persistent id (not the String identifier) of the currently-selected article, for scrolling.
    private var currentItemID: Article.ID? {
        results.first { $0.identifier == currentArticleID }?.id
    }

    var body: some View {
        ManagedList(
            items: results,
            searchText: $searchText,
            searchPrompt: "Search articles",
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "No articles yet. Add feeds, then pull to refresh.",
            scrollToID: currentItemID,
            onDelete: { offsets in
                guard let article = offsets.map({ results[$0] }).first else { return }
                articleToDelete = article
            },
            leadingActions: { article in
                Button {
                    guard let starredTag else { return }
                    article.setStarred(!article.isStarred, using: starredTag)
                    try? modelContext.save()
                    Haptics.impact(.light)
                } label: {
                    Label(article.isStarred ? "Unstar" : "Star",
                          systemImage: article.isStarred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button {
                    UpdateActivity.shared.restart {
                        await AggregationService(context: modelContext).forceReload(article: article)
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .tint(.orange)
            }
        ) { article in
            Button { onSelect(article) } label: { row(article) }
                .buttonStyle(.plain)
                .listRowBackground(article.identifier == currentArticleID
                                   ? Color.accentColor.opacity(0.15) : nil)
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
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
                Button {
                    showFilter = true
                } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilter) { TagFilterView() }
        .confirmationDialog(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let article = articleToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    modelContext.delete(article)
                    try? modelContext.save()
                    Haptics.notify(.success)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let article = articleToDelete {
                Text(String(localized: "Delete \u{201C}\(article.title)\u{201D}? This cannot be undone."))
            }
        }
    }

    private func row(_ article: Article) -> some View {
        HStack(spacing: 12) {
            FeedLogoView(hash: article.feed?.logoHash)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let name = article.feed?.name, !name.isEmpty {
                        Text(name)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(article.date, style: .date)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }
}
```

- [ ] **Step 4: Present the list sheet + add `openArticle` in `ReaderScreen`**

In `Yana/Reader/ReaderHostView.swift`, add the list sheet right after the settings sheet (the `.sheet(isPresented: $appState.showSettings)` line):
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

Add the handler near `goToFeed`'s former location (e.g. after `copyLink`):
```swift
    /// Jump the reader to an article picked from the list. Recompute first so an in-list filter
    /// change is reflected, then resolve by identifier (not a stale index) and dismiss the sheet.
    private func openArticle(_ article: Article) {
        recomputeFilter()
        if let i = TimelinePageIndex.index(of: article.identifier, in: filteredArticles) {
            appState.currentIndex = i
            settings.timelineAnchorIdentifier = article.identifier
        }
        appState.showArticleList = false
    }
```

- [ ] **Step 5: Build + run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. Manual check: list button opens the sheet; the current article row is tinted and scrolled into view; the list's filter button edits the same filter as the reader; tapping a row dismisses and jumps the reader; search/star/reload/delete still work.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift Yana/Reader/ReaderHostView.swift YanaTests/ArticleListFilterTests.swift
git commit -m "feat(reader): article-list sheet shares filter, highlights and jumps to selection"
```

---

## Task 6: Delete dead views + final verification

**Files:**
- Delete: `Yana/Views/ArticleDetailView.swift`
- Delete: `Yana/Views/Config/ArticleTagFilterView.swift`

**Interfaces:** none produced; pure removal.

- [ ] **Step 1: Confirm both files are unreferenced**

Run: `grep -rn "ArticleDetailView\|ArticleTagFilterView" Yana/ YanaTests/ YanaUITests/`
Expected: no matches (the rewrite in Task 5 removed the last usages).

- [ ] **Step 2: Delete the files**

```bash
git rm Yana/Views/ArticleDetailView.swift Yana/Views/Config/ArticleTagFilterView.swift
```

- [ ] **Step 3: Regenerate, build, and test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Verify translations are complete**

Run: `grep -c '"state" : "new"' Yana/Resources/Localizable.xcstrings || true`
Expected: `0` (no untranslated entries left from this work). Manually confirm `"Article list"` and `"Manage your feeds and the tags applied to articles."` each have a `de` `"state" : "translated"` value, and that `"Go to feed"`, `"Organize your sources and browse everything you've collected."`, and `"Sources, AI, notifications, and library preferences."` are gone.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove dead ArticleDetailView and ArticleTagFilterView"
```

---

## Self-Review Notes

- **Spec coverage:** article-list button left of nothing-now/leftmost (Task 2) ✓; filter on right between star and menu (Task 2) ✓; Settings in overflow menu (Task 2) ✓; shared filter + same data (Task 5) ✓; highlight current + auto-scroll (Tasks 3+5) ✓; search + swipe actions kept (Task 5) ✓; jump-to-article (Task 5) ✓; Settings page with top Feeds/Tags section + gear-from-menu (Tasks 2+4) ✓; hub deleted (Task 4) ✓; Go-to-feed removed (Task 1) ✓; dead-code cleanup (Task 6) ✓; translations (Tasks 1,2,4,6) ✓.
- **Type consistency:** `ReaderMenuConfig`/`config(hasURL:aiReady:)`, `onShowArticleList`, `AppState.showArticleList`, `ManagedList.scrollToID: Item.ID?`, `ArticleListView(currentArticleID:onSelect:)`, `openArticle(_:)` used consistently across tasks.
- **Note:** UIKit chrome and SwiftUI sheets are verified by build + manual check (this codebase unit-tests pure logic only); the genuinely testable logic — the shared filter pipeline and identifier-based jump resolution — is covered in Task 5.
