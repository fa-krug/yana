# Unified Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the config hub's Articles, Feeds, and Tags screens a consistent searchable + editable baseline through one shared list component, and add a tag filter to Articles.

**Architecture:** A new generic `ManagedList<Item, Row>` view owns the common chrome (`.searchable`, swipe/edit-mode delete, optional reorder, search-aware empty state). Each screen keeps its own SwiftData `@Query` and search/filter state, computes its filtered items, and passes them in with a row builder and edit closures. The Articles tag filter reuses the existing `TagFilter.apply` and `ArticleSearch.filter` helpers and is held in transient local `@State` (never `AppSettings`).

**Tech Stack:** SwiftUI, SwiftData, Swift 6 (strict concurrency, `@MainActor`), Swift Testing, XcodeGen.

## Global Constraints

- Platform: iOS 26.0+; Swift 6 strict concurrency; `@MainActor` on UI/model-touching code.
- SwiftData is the source of truth: views read via `@Query`, writes go through `modelContext` + `try? modelContext.save()`.
- All user-facing strings localizable via `String(localized:)` / `LocalizedStringKey`; catalog is `Yana/Resources/Localizable.xcstrings` (auto-extracted on build).
- New `.swift` files under `Yana/` or `YanaTests/` require `xcodegen generate` before they compile (sources are directory globs).
- Tests use Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`), `@MainActor` where they touch models.
- The Articles tag filter MUST stay independent of the home timeline filter — it never reads or writes `AppSettings`.
- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:<id>`

---

### Task 1: `NameSearch` helper

Pure case/diacritic-insensitive name matcher used to search the Feeds and Tags lists. Mirrors the shape of the existing `ArticleSearch`, but operates on plain strings (no `@MainActor` needed).

**Files:**
- Create: `Yana/Utilities/NameSearch.swift`
- Test: `YanaTests/NameSearchTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum NameSearch`
  - `static func matches(_ name: String, query: String) -> Bool`
  - `static func filter<T>(_ items: [T], query: String, name: (T) -> String) -> [T]`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/NameSearchTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("NameSearch")
struct NameSearchTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(NameSearch.matches("Heise", query: "   "))
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(NameSearch.matches("Méin MMO", query: "mein"))
        #expect(NameSearch.matches("Tagesschau", query: "TAGES"))
    }

    @Test func nonMatchExcluded() {
        #expect(!NameSearch.matches("Heise", query: "reddit"))
    }

    @Test func filterReturnsOnlyMatches() {
        let names = ["Heise", "Reddit", "heise blog"]
        #expect(NameSearch.filter(names, query: "heise", name: { $0 }).count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/NameSearchTests`
Expected: FAIL — `cannot find 'NameSearch' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Yana/Utilities/NameSearch.swift`:

```swift
import Foundation

/// Case/diacritic-insensitive substring match over a name, used to search the Feeds and Tags
/// lists. An empty / whitespace-only query matches everything.
enum NameSearch {
    static func matches(_ name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return name.localizedStandardContains(q)
    }

    static func filter<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { name($0).localizedStandardContains(q) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/NameSearchTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/NameSearch.swift YanaTests/NameSearchTests.swift
git commit -m "feat: add NameSearch helper for list name filtering"
```

---

### Task 2: `ManagedList` shared component

The reusable searchable + editable list. Owns `.searchable`, delete (swipe + edit-mode minus via `.onDelete`), optional reorder (`.onMove`, suppressed while searching), and the search-aware empty state. No unit test — this matches the codebase convention that views are verified by build, not unit-tested (e.g. `FeedsView`, `TagsView` have no view tests). The pure composition logic it relies on is tested in Tasks 1 and 5.

**Files:**
- Create: `Yana/Views/Config/ManagedList.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct ManagedList<Item: Identifiable, Row: View>: View` with members:
    - `let items: [Item]`
    - `@Binding var searchText: String`
    - `var searchPrompt: LocalizedStringKey`
    - `var emptyTitle: LocalizedStringKey`
    - `var emptyIcon: String`
    - `var emptyDescription: LocalizedStringKey`
    - `var onDelete: ((IndexSet) -> Void)? = nil` — offsets index into `items`
    - `var onMove: ((IndexSet, Int) -> Void)? = nil` — Tags only; suppressed while searching
    - `@ViewBuilder var row: (Item) -> Row`

> Interface note vs. spec: `onDelete`/`onMove` are `IndexSet`-based (not `Item`-based) so they wire directly to SwiftUI's `.onDelete(perform:)` / `.onMove(perform:)`, which gives both swipe-to-delete *and* edit-mode delete and integrates with `EditButton` for Tags. Each screen maps offsets into its own filtered array.

- [ ] **Step 1: Create the component**

Create `Yana/Views/Config/ManagedList.swift`:

```swift
import SwiftUI

/// Reusable searchable + editable list used by the config hub's Feeds, Tags, and Articles
/// screens. Owns the common chrome — `.searchable`, delete (swipe + edit-mode), optional
/// reorder, and a search-aware empty state. Each screen keeps its own `@Query`, computes the
/// filtered `items`, and passes a row builder plus edit closures.
///
/// Reorder and search don't compose (moving rows within a filtered subset is ambiguous), so
/// `onMove` is suppressed while a search is active.
struct ManagedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var searchText: String
    var searchPrompt: LocalizedStringKey

    var emptyTitle: LocalizedStringKey
    var emptyIcon: String
    var emptyDescription: LocalizedStringKey

    var onDelete: ((IndexSet) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    @ViewBuilder var row: (Item) -> Row

    private var reorderEnabled: Bool {
        onMove != nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
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
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/ManagedList.swift project.yml Yana.xcodeproj
git commit -m "feat: add ManagedList reusable searchable/editable list"
```

---

### Task 3: Adopt `ManagedList` in `FeedsView` + add search

Rebuild `FeedsView` on `ManagedList`: add name search, route delete through `onDelete`, keep the per-feed Update swipe action (as an extra `.swipeActions` on the row), and keep the existing toolbar (add `+`, Update All, OPML menu), `fileImporter`/`sheet`/`alert`, and row chrome.

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`

**Interfaces:**
- Consumes: `ManagedList` (Task 2), `NameSearch.filter` (Task 1).
- Produces: nothing new (internal view).

- [ ] **Step 1: Replace the body and add search state**

In `Yana/Views/Config/FeedsView.swift`, add `@State private var searchText = ""` alongside the other `@State` properties, add the filtered-feeds computed property, and replace `var body` and the `private func row` stays unchanged. Replace the `List { ... }.navigationTitle("Feeds").overlay { ... }` block (lines 16–47 in the current file) so the body reads:

```swift
    @State private var searchText = ""

    private var filteredFeeds: [Feed] {
        NameSearch.filter(feeds, query: searchText, name: \.name)
    }

    var body: some View {
        ManagedList(
            items: filteredFeeds,
            searchText: $searchText,
            searchPrompt: "Search feeds",
            emptyTitle: "No Feeds",
            emptyIcon: "list.bullet.rectangle",
            emptyDescription: "Tap + to add your first feed.",
            onDelete: { offsets in
                for index in offsets { modelContext.delete(filteredFeeds[index]) }
                try? modelContext.save()
            }
        ) { feed in
            NavigationLink {
                FeedEditorView(feed: feed)
            } label: {
                row(feed)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await updateOne(feed) }
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
                .disabled(isUpdating)
            }
        }
        .navigationTitle("Feeds")
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { exportOPML() } label: { Label("Export OPML", systemImage: "square.and.arrow.up") }
                    Button { isImporting = true } label: { Label("Import OPML", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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
        .alert("Feeds", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }
```

Leave `private func row(_:)`, `updateAll()`, `updateOne(_:)`, `exportOPML()`, and `handleImport(_:)` unchanged. (The old `.overlay`/`ContentUnavailableView("No Feeds"...)` is removed — `ManagedList` now owns the empty state.)

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "feat: make FeedsView searchable via ManagedList"
```

---

### Task 4: Adopt `ManagedList` in `TagsView` + add search

Rebuild `TagsView` on `ManagedList`: add name search, route delete through `onDelete` (skipping the built-in Starred tag), wire reorder through `onMove` (auto-suppressed while searching), and keep the add `+` button, `EditButton`, sheet editor, and built-in lock chrome.

**Files:**
- Modify: `Yana/Views/Config/TagsView.swift`

**Interfaces:**
- Consumes: `ManagedList` (Task 2), `NameSearch.filter` (Task 1).
- Produces: nothing new.

- [ ] **Step 1: Replace the body and edit handlers**

Replace the contents of the `TagsView` struct (keep imports) so it reads:

```swift
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var editingTag: Tag?
    @State private var isCreating = false
    @State private var searchText = ""

    private var filteredTags: [Tag] {
        NameSearch.filter(tags, query: searchText, name: \.name)
    }

    var body: some View {
        ManagedList(
            items: filteredTags,
            searchText: $searchText,
            searchPrompt: "Search tags",
            emptyTitle: "No Tags",
            emptyIcon: "tag",
            emptyDescription: "Tap + to create your first tag.",
            onDelete: delete,
            onMove: move
        ) { tag in
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
            let tag = filteredTags[index]
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

(`move` operates on the full `tags` array — safe because `ManagedList` suppresses reorder while searching, so `filteredTags == tags` whenever `onMove` fires.)

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/Config/TagsView.swift
git commit -m "feat: make TagsView searchable via ManagedList"
```

---

### Task 5: Adopt `ManagedList` in `ArticleListView` + delete + tag filter

Rebuild `ArticleListView` on `ManagedList`: add swipe-to-delete, add a Filter toolbar button + sheet driven by transient local `@State`, and compose `ArticleSearch.filter` with `TagFilter.apply`. Add the new `ArticleTagFilterView` sheet. Cover the search+filter composition with a unit test.

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`
- Create: `Yana/Views/Config/ArticleTagFilterView.swift`
- Test: `YanaTests/ArticleListFilteringTests.swift`

**Interfaces:**
- Consumes: `ManagedList` (Task 2), `ArticleSearch.filter` (existing), `TagFilter.apply(to:disabledTagNames:includeUntagged:)` (existing, `Yana/Utilities/TimelineFiltering.swift`).
- Produces:
  - `struct ArticleTagFilterView: View` with `@Binding var disabledTagNames: Set<String>` and `@Binding var includeUntagged: Bool`.

- [ ] **Step 1: Write the failing composition test**

Create `YanaTests/ArticleListFilteringTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleListFiltering")
struct ArticleListFilteringTests {
    private func article(title: String, tagName: String?) -> Article {
        let a = Article(title: title, identifier: UUID().uuidString, url: "u")
        if let tagName { a.tags = [Tag(name: tagName)] }
        return a
    }

    @Test func searchThenTagFilterCompose() {
        let articles = [
            article(title: "Swift news", tagName: "Tech"),
            article(title: "Swift cooking", tagName: "Food"),
            article(title: "Rust news", tagName: "Tech"),
        ]
        let searched = ArticleSearch.filter(articles, query: "swift") // -> 2 articles
        let filtered = TagFilter.apply(to: searched, disabledTagNames: ["Food"], includeUntagged: true)
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Swift news")
    }

    @Test func untaggedExcludedWhenFlagOff() {
        let articles = [article(title: "Swift", tagName: nil)]
        let searched = ArticleSearch.filter(articles, query: "swift")
        #expect(TagFilter.apply(to: searched, disabledTagNames: [], includeUntagged: false).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleListFilteringTests`
Expected: FAIL — `ArticleListFilteringTests.swift` does not yet exist in the target until `xcodegen generate`; after generation it FAILS to build only if the helpers are missing. Since `ArticleSearch`/`TagFilter` already exist, this test should actually PASS immediately. That is expected: it is a regression guard for the composition the view relies on. Proceed to Step 3.

- [ ] **Step 3: Create `ArticleTagFilterView`**

Create `Yana/Views/Config/ArticleTagFilterView.swift`:

```swift
import SwiftData
import SwiftUI

/// Transient tag filter for the Articles list. Mirrors `TagFilterView`'s layout but writes to
/// the caller's local `@State` (via bindings) instead of `AppSettings`, so it never affects
/// the home timeline filter. All tags active by default.
struct ArticleTagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @Binding var disabledTagNames: Set<String>
    @Binding var includeUntagged: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    Toggle(tag.name, isOn: Binding(
                        get: { !disabledTagNames.contains(tag.name) },
                        set: { active in
                            if active { disabledTagNames.remove(tag.name) }
                            else { disabledTagNames.insert(tag.name) }
                        }
                    ))
                }
                Toggle(String(localized: "Untagged"), isOn: $includeUntagged)
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
```

- [ ] **Step 4: Rebuild `ArticleListView`**

Replace the contents of `Yana/Views/Config/ArticleListView.swift` (keep the leading doc comment) with:

```swift
import SwiftData
import SwiftUI

/// Searchable + filterable list of all articles (newest first), reachable from the config hub.
/// Tapping a row opens a read-only detail; swipe to delete. Search matches
/// title/content/author/feed name in memory; the tag filter is transient (local state, never
/// `AppSettings`) so it never affects the home timeline.
struct ArticleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @State private var searchText = ""
    @State private var disabledTagNames: Set<String> = []
    @State private var includeUntagged = true
    @State private var showFilter = false

    private var results: [Article] {
        let searched = ArticleSearch.filter(allArticles, query: searchText)
        return TagFilter.apply(to: searched, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged)
    }

    private var isFilterActive: Bool {
        !disabledTagNames.isEmpty || !includeUntagged
    }

    var body: some View {
        ManagedList(
            items: results,
            searchText: $searchText,
            searchPrompt: "Search articles",
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "Add feeds and refresh to see articles here.",
            onDelete: { offsets in
                for index in offsets { modelContext.delete(results[index]) }
                try? modelContext.save()
            }
        ) { article in
            NavigationLink {
                ArticleDetailView(article: article)
            } label: {
                row(article)
            }
        }
        .navigationTitle("Articles")
        .toolbar {
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
        .sheet(isPresented: $showFilter) {
            ArticleTagFilterView(disabledTagNames: $disabledTagNames, includeUntagged: $includeUntagged)
        }
    }

    private func row(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if let name = article.feed?.name, !name.isEmpty {
                    Text(name).foregroundStyle(Color.accentColor)
                    Text("·")
                }
                Text(article.date, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 5: Run the test suite + build**

Run: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleListFilteringTests`
Expected: PASS (2 tests).
Then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift Yana/Views/Config/ArticleTagFilterView.swift YanaTests/ArticleListFilteringTests.swift
git commit -m "feat: add delete and tag filter to ArticleListView via ManagedList"
```

---

### Task 6: Full test pass + localization check

Confirm the whole suite is green and new strings are in the catalog.

**Files:**
- Possibly modify: `Yana/Resources/Localizable.xcstrings` (Xcode auto-extracts new literals on build; verify and add translations if the project tracks them).

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests PASS (including existing `ArticleSearchTests`, `TimelineFilteringTests`, `TagTests`).

- [ ] **Step 2: Verify new strings extracted**

Open `Yana/Resources/Localizable.xcstrings` and confirm the new literals are present: `"Search feeds"`, `"Search tags"`, `"No Tags"`, `"Tap + to create your first tag."` (`"Search articles"`, `"No Articles"`, `"No Feeds"`, `"Filter"`, `"Untagged"`, `"Done"`, `"Delete"` already exist). If the project keeps non-English translations, add them following existing entries; otherwise the English source state is sufficient.

- [ ] **Step 3: Commit (if the catalog changed)**

```bash
git add Yana/Resources/Localizable.xcstrings
git commit -m "chore: add localized strings for unified lists"
```

---

## Self-Review

**Spec coverage:**
- Shared component → Task 2 (`ManagedList`). ✅
- Articles searchable (kept) + editable (delete) + filter → Task 5. ✅
- Feeds searchable + editable (kept) → Task 3. ✅
- Tags searchable + editable (kept, incl. reorder) → Task 4. ✅
- Reorder suppressed while searching → Task 2 (`reorderEnabled`). ✅
- Article filter by tag, reusing timeline tag set + Untagged → Task 5 (`ArticleTagFilterView`). ✅
- Filter independent of `AppSettings` → Task 5 (local `@State`, never `AppSettings`). ✅
- Reuse `TagFilter.apply` / `ArticleSearch.filter` → Task 5. ✅
- Feed/Tag name search via `localizedStandardContains` → Task 1 (`NameSearch`, extracted as a small testable helper rather than inline). ✅
- Localization → Task 6. ✅
- Testing (composition + name search pure logic) → Tasks 1, 5. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step has full code; every command has expected output. ✅

**Type consistency:** `ManagedList` member names/types (`onDelete: ((IndexSet) -> Void)?`, `onMove: ((IndexSet, Int) -> Void)?`, `searchPrompt: LocalizedStringKey`) match every call site in Tasks 3–5. `NameSearch.filter(_:query:name:)` signature matches its calls (`name: \.name`). `ArticleTagFilterView(disabledTagNames:includeUntagged:)` bindings match Task 5's `@State`. `TagFilter.apply(to:disabledTagNames:includeUntagged:)` matches the existing helper. ✅

**Note on spec deviation:** the spec sketched `onDelete` as `((Item) -> Void)?`; the plan uses `((IndexSet) -> Void)?` to wire natively into `.onDelete(perform:)` (gives edit-mode delete + `EditButton` integration). Behavior is unchanged; rationale documented in Task 2.
