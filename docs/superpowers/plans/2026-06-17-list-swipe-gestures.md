# List Swipe Gestures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standardize config-hub list swipes so trailing (right-to-left) deletes and leading (left-to-right) runs a secondary action, on the Articles and Feeds lists.

**Architecture:** Add an optional leading-actions view builder to the shared `ManagedList` component (with an `EmptyView` default so the Tags list is untouched). `ArticleListView` adds Star + Force-update on the leading edge and a delete-confirmation dialog on the trailing edge; `FeedsView` moves its Update button to the leading edge and routes delete through `ManagedList`'s `onDelete`.

**Tech Stack:** SwiftUI, SwiftData, Swift 6 (strict concurrency, `@MainActor`).

## Global Constraints

- Platform: iOS 26.0+; build/test with `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17'`.
- Swift 6 strict concurrency; views are `@MainActor`.
- All new user-facing strings MUST be added to `Yana/Resources/Localizable.xcstrings` with a German (`de`) translation marked `"state" : "translated"`. German uses Apple style (infinitive for actions, no "Du"/"Sie").
- Follow existing patterns; `ManagedList` is the single owner of shared list chrome.
- Verification for SwiftUI swipe chrome is build + manual (the test suite covers model logic, not gestures). No new unit-testable helper is introduced, so tasks are build-verified.

---

### Task 1: Add leading-actions builder to `ManagedList`

**Files:**
- Modify: `Yana/Views/Config/ManagedList.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - A third generic parameter `Leading: View` on `ManagedList`.
  - A new property `@ViewBuilder var leadingActions: (Item) -> Leading` declared immediately before `row`, so the synthesized memberwise init exposes `leadingActions:` then the trailing `row:` closure.
  - A convenience `init` in an extension constrained to `Leading == EmptyView` that omits `leadingActions` (defaults it to `{ _ in EmptyView() }`), keeping existing call sites that pass no leading actions source-compatible.

- [ ] **Step 1: Add the generic parameter and property**

Change the struct declaration and add the `leadingActions` property right before `row`:

```swift
struct ManagedList<Item: Identifiable, Row: View, Leading: View>: View {
    let items: [Item]
    @Binding var searchText: String
    var searchPrompt: LocalizedStringKey

    var emptyTitle: LocalizedStringKey
    var emptyIcon: String
    var emptyDescription: LocalizedStringKey

    var onDelete: ((IndexSet) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    @ViewBuilder var leadingActions: (Item) -> Leading
    @ViewBuilder var row: (Item) -> Row
```

- [ ] **Step 2: Attach the leading swipe in `body`**

Replace the `ForEach` block so each row gets a leading swipe (default full-swipe behavior; the caller decides button order):

```swift
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
```

- [ ] **Step 3: Add the `EmptyView` convenience init**

Append this extension at the end of the file so callers (e.g. Tags) that supply no leading actions still compile:

```swift
extension ManagedList where Leading == EmptyView {
    init(
        items: [Item],
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        emptyDescription: LocalizedStringKey,
        onDelete: ((IndexSet) -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self._searchText = searchText
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.emptyDescription = emptyDescription
        self.onDelete = onDelete
        self.onMove = onMove
        self.leadingActions = { _ in EmptyView() }
        self.row = row
    }
}
```

- [ ] **Step 4: Update the doc comment**

Update the top-of-file doc comment to mention the leading-edge action. Replace the first sentence block:

```swift
/// Reusable searchable + editable list used by the config hub's Feeds, Tags, and Articles
/// screens. Owns the common chrome — `.searchable`, trailing delete (swipe + edit-mode),
/// an optional leading-edge swipe action per row, optional reorder, and a search-aware
/// empty state. Each screen keeps its own `@Query`, computes the filtered `items`, and
/// passes a row builder plus edit closures. Callers that need no leading action use the
/// `EmptyView` convenience initializer.
```

- [ ] **Step 5: Build to verify Tags/Feeds/Articles still compile**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (TagsView uses the convenience init unchanged; FeedsView/ArticleListView still use the memberwise init — they are updated in later tasks).

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/ManagedList.swift
git commit -m "feat: add optional leading-edge swipe action to ManagedList"
```

---

### Task 2: Move Feeds Update to the leading edge; delete via `onDelete`

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift:30-50`

**Interfaces:**
- Consumes: `ManagedList` leading-actions builder + `onDelete` (Task 1).
- Produces: no new symbols. Uses existing `updateOne(_:)`, `feedToDelete`, `filteredFeeds`, `isUpdating`.

- [ ] **Step 1: Add an `onDelete` and `leadingActions`; remove the inline trailing `.swipeActions`**

Replace the `ManagedList(...) { feed in ... }` block (lines 23–50) with:

```swift
        ManagedList(
            items: filteredFeeds,
            searchText: $searchText,
            searchPrompt: "Search feeds",
            emptyTitle: "No Feeds",
            emptyIcon: "list.bullet.rectangle",
            emptyDescription: "Tap + to add your first feed.",
            onDelete: { offsets in
                // Resolve immediately so stale indices can't delete the wrong feed
                guard let feed = offsets.map({ filteredFeeds[$0] }).first else { return }
                feedToDelete = feed
            },
            leadingActions: { feed in
                Button {
                    Task { await updateOne(feed) }
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
                .disabled(isUpdating)
            }
        ) { feed in
            NavigationLink {
                FeedEditorView(feed: feed)
            } label: {
                row(feed)
            }
        }
```

Note: the previous `.swipeActions(edge: .trailing) { ... }` block is removed entirely; delete now comes from `onDelete` (trailing swipe-to-delete) and still opens the existing confirmation dialog via `feedToDelete`.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual check**

On the Feeds list: leading swipe (left-to-right) shows **Update**; trailing swipe (right-to-left) shows **Delete** and opens the "Delete Feed?" confirmation. "Update All" toolbar still works.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "feat: feeds leading-swipe update, trailing-swipe delete"
```

---

### Task 3: Articles — leading Star + Update, trailing delete with confirmation

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ManagedList` leading-actions builder + `onDelete` (Task 1); `Article.setStarred(_:using:)`, `Article.isStarred`, `Tag.starredName`, `AggregationService.update(article:)` (all existing).
- Produces: no new symbols.

- [ ] **Step 1: Add state and the Starred-tag query**

In `ArticleListView`, add below the existing `@State` declarations (after line 14):

```swift
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var articleToDelete: Article?

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }
```

- [ ] **Step 2: Replace the `ManagedList` call to add leading actions and a confirming delete**

Replace the `ManagedList(...) { article in ... }` block (lines 26–43) with:

```swift
        ManagedList(
            items: results,
            searchText: $searchText,
            searchPrompt: "Search articles",
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "Add feeds and refresh to see articles here.",
            onDelete: { offsets in
                // Resolve immediately so stale indices can't delete the wrong article
                guard let article = offsets.map({ results[$0] }).first else { return }
                articleToDelete = article
            },
            leadingActions: { article in
                Button {
                    guard let starredTag else { return }
                    article.setStarred(!article.isStarred, using: starredTag)
                    try? modelContext.save()
                } label: {
                    Label(article.isStarred ? "Unstar" : "Star",
                          systemImage: article.isStarred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button {
                    Task { await AggregationService(context: modelContext).update(article: article) }
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        ) { article in
            NavigationLink {
                ArticleDetailView(article: article)
            } label: {
                row(article)
            }
        }
```

Note: Star is declared first, so a full leading swipe stars/unstars (reversible). Update is the second leading button.

- [ ] **Step 3: Add the delete confirmation dialog**

Add this modifier to the view chain, immediately after the existing `.sheet(isPresented: $showFilter) { ... }` block (after line 58):

```swift
        .confirmationDialog(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let article = articleToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    modelContext.delete(article)
                    try? modelContext.save()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let article = articleToDelete {
                Text(String(localized: "Delete \u{201C}\(article.title)\u{201D}? This cannot be undone."))
            }
        }
```

- [ ] **Step 4: Add localized strings**

Add these entries to `Yana/Resources/Localizable.xcstrings` (under `"strings"`), each with the German translation marked `"state" : "translated"`. Match the existing entry shape (see the `"Update"` entry which has a `de` `stringUnit`). New keys and German values:

- `"Star"` → `"Markieren"`
- `"Unstar"` → `"Markierung entfernen"`
- `"Delete Article?"` → `"Artikel löschen?"`
- `` "Delete \u{201C}\(article.title)\u{201D}? This cannot be undone." `` — key string `"Delete “%@”? This cannot be undone."` → German `"„%@“ löschen? Dies kann nicht rückgängig gemacht werden."`

Use the existing `"Delete”`/`"Cancel"`/`"Update"` entries as-is (already present).

For each new key, the JSON shape is:

```json
"Star" : {
  "localizations" : {
    "de" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Markieren"
      }
    }
  }
}
```

(For the interpolated delete-message key, the catalog key is the format string `Delete “%@”? This cannot be undone.` with the `%@` placeholder, and the German `value` uses the same `%@` placeholder.)

- [ ] **Step 5: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Verify localization completeness**

Run:
```bash
python3 -c "
import json
d=json.load(open('Yana/Resources/Localizable.xcstrings'))
for k in ['Star','Unstar','Delete Article?']:
    e=d['strings'].get(k)
    assert e and e['localizations']['de']['stringUnit']['state']=='translated', k
print('de translations OK')
"
```
Expected: `de translations OK`.

- [ ] **Step 7: Manual check**

On the Articles list: leading swipe shows **Star** (full-swipe stars/unstars) + **Update**; trailing swipe shows **Delete** and opens the "Delete Article?" confirmation. Starring here is reflected in the home reader's star state.

- [ ] **Step 8: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat: articles leading-swipe star/update, trailing-swipe delete with confirmation"
```

---

## Self-Review Notes

- **Spec coverage:** ManagedList leading builder (Task 1), Articles star+update+confirm-delete (Task 3), Feeds update-leading/delete-trailing (Task 2), Tags unchanged (no task — by design), localization (Task 3 Step 4). All spec sections covered.
- **Deviation from spec:** spec suggested `allowsFullSwipe: false` for the Article leading edge; the plan instead keeps default full-swipe with **Star declared first** so the full-swipe action is the reversible star. Simpler shared API, better UX. Unstar icon is `star.slash`.
- **Type consistency:** `leadingActions`/`onDelete` signatures match across Tasks 1–3; `setStarred(_:using:)`, `update(article:)`, `Tag.starredName` verified against current source.
