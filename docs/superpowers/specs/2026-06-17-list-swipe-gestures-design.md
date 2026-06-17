# List Swipe Gestures — Design

**Date:** 2026-06-17
**Status:** Approved (pending spec review)

## Goal

Standardize the config-hub list swipe gestures so direction maps to intent:

- **Trailing edge (swipe right-to-left): Delete.**
- **Leading edge (swipe left-to-right): a secondary action** (force-update, star, etc.).

This applies to the **Articles** and **Feeds** lists. The **Tags** list is left
unchanged (delete-only; tap still opens the editor) — a leading swipe there would only
duplicate the existing tap-to-edit.

## Current State

All three config lists are built on the reusable `ManagedList` component
(`Yana/Views/Config/ManagedList.swift`), which owns the shared chrome: `.searchable`,
trailing swipe-to-delete via `.onDelete`, optional reorder, and the empty state.

- **`ArticleListView`** — passes `onDelete` (immediate delete, no confirmation). No leading swipe.
- **`FeedsView`** — does *not* use `ManagedList.onDelete`; instead attaches its own
  `.swipeActions(edge: .trailing)` per row with **Delete** (opens a confirmation dialog) +
  **Update** buttons together on the trailing edge.
- **`TagsView`** — passes `onDelete` (opens a confirmation dialog). No leading swipe.

## Design

### 1. `ManagedList` — add an optional leading-actions builder

Add a third generic parameter `Leading: View` and a leading-actions view builder applied
per row:

```swift
struct ManagedList<Item: Identifiable, Row: View, Leading: View>: View {
    // ...existing properties...
    @ViewBuilder var leadingActions: (Item) -> Leading
    @ViewBuilder var row: (Item) -> Row
}
```

In `body`, attach the leading swipe to each row; trailing delete stays exactly as today:

```swift
ForEach(items) { item in
    row(item)
        .swipeActions(edge: .leading) { leadingActions(item) }
}
.onDelete(perform: onDelete)
.onMove(perform: reorderEnabled ? onMove : nil)
```

Because `TagsView` supplies no leading actions, provide a convenience initializer that
defaults `Leading` to `EmptyView`, so existing call sites that omit `leadingActions`
continue to compile unchanged:

```swift
extension ManagedList where Leading == EmptyView {
    // Same parameters as the main init, minus `leadingActions`,
    // defaulting it to `{ _ in EmptyView() }`.
}
```

An empty `.swipeActions(edge: .leading) { EmptyView() }` renders no leading action, so
Tags keep their current behavior with no special-casing.

### 2. `ArticleListView`

**Leading edge — two buttons, `allowsFullSwipe: false`** (so neither fires on an
accidental full swipe):

1. **Star / Unstar** — toggles the built-in Starred tag.
   - Add `@Query` for built-in tags and resolve the Starred tag, mirroring
     `ArticleReaderView` (`builtInTags` → `starredTag`).
   - Action: `article.setStarred(!article.isStarred, using: starredTag)` then save.
   - Label: `Image(systemName: article.isStarred ? "star.slash" : "star")`, tinted `.yellow`.
   - No-op guard if `starredTag` is nil.
2. **Force-update** — `await AggregationService(context: modelContext).update(article:)`.
   - Label: `Label("Update", systemImage: "arrow.clockwise")`, tinted `.blue`.

**Trailing edge — Delete with confirmation (new):**

- `onDelete` no longer deletes immediately. It resolves the `Article` from the offsets and
  stores it in `@State private var articleToDelete: Article?` (resolve the object
  immediately, matching the stale-index guard pattern in `TagsView.onDelete`).
- Add a `.confirmationDialog` keyed on `articleToDelete` (mirroring `FeedsView`'s feed
  delete dialog) with a destructive **Delete** and **Cancel**. On confirm:
  `modelContext.delete(article); try? modelContext.save()`.

### 3. `FeedsView`

Unify with the shared pattern — remove the inline per-row `.swipeActions(edge: .trailing)`:

- **Leading edge — Update:** move the existing Update button into `ManagedList`'s
  `leadingActions`. Action unchanged: `Task { await updateOne(feed) }`,
  `Label("Update", systemImage: "arrow.clockwise")`, tinted `.blue`, disabled while
  `isUpdating`.
- **Trailing edge — Delete:** pass `onDelete` to `ManagedList`; the closure resolves the
  feed from the offsets and sets `feedToDelete`, preserving the existing confirmation
  dialog and its message. The custom `.swipeActions` block on the row is deleted.

### 4. `TagsView`

No changes. Delete-only (trailing, with confirmation); tap opens `TagEditorView`.

## Localization

Add any new user-facing strings to `Yana/Resources/Localizable.xcstrings` with German
translations (`"state": "translated"`), Apple style:

- "Star" → "Markieren"
- "Unstar" → "Markierung entfernen"
- Reuse existing "Update" / "Delete" / "Cancel" entries if already present; otherwise add
  them with German equivalents ("Aktualisieren" / "Löschen" / "Abbrechen").

Use accessibility labels for the icon-only star button (e.g. "Star article" / "Unstar
article", as in `ArticleReaderView`).

## Testing

- Build for the iPhone 17 simulator.
- Unit tests cover model logic, not SwiftUI swipe gestures, so the existing
  `setStarred` / delete / `update(article:)` behavior remains covered. Add a focused test
  only if a new non-trivial helper is introduced (none is anticipated).
- Manual verification: on the Articles list, leading swipe shows Star + Update and trailing
  swipe shows Delete with a confirmation; on the Feeds list, leading swipe shows Update and
  trailing swipe shows Delete with the existing confirmation; Tags unchanged.

## Out of Scope

- The home `ArticleReaderView` swipe paging (untouched).
- Any leading swipe on the Tags list.
- True single-article re-fetch (`update(article:)` still refreshes the owning feed, per its
  current implementation).
