# Sheet-based feed/tag creation

## Problem

Creating a new feed or tag currently happens via a pushed `NavigationLink` editor
that **silently auto-saves on dismiss** (`.onDisappear { save() }`). There is no
explicit confirm step and no way to back out of a half-entered new item without it
either being silently dropped (if invalid) or silently committed (if valid). This is
unclear and easy to trigger accidentally.

## Goal

Creating a new feed or tag opens in a **sheet** with explicit actions:

- **Cancel** (top-left `xmark` icon): dismiss without inserting anything. Swiping the
  sheet down behaves the same.
- **Confirm** (top-right `checkmark` icon): validate, insert the new feed/tag, then
  dismiss. Disabled while the entry is invalid.

**Editing an existing feed or tag is unchanged**: it still pushes the editor and
auto-saves on dismiss.

## Scope

Create flow only. Edit flow untouched.

## Design

### Editor views

`FeedEditorView` and `TagEditorView` already distinguish create from edit via
`feed == nil` / `tag == nil`. Branch on that signal:

**Create mode (`feed == nil` / `tag == nil`):**
- Remove `.onDisappear { save() }` so dismissing (Cancel or swipe-down) discards.
- Add a toolbar:
  - `.topBarLeading`: Button with `Image(systemName: "xmark")`, accessibility label
    `"Cancel"`, action `dismiss()`.
  - `.topBarTrailing`: Button with `Image(systemName: "checkmark")`, accessibility
    label `"Save"`, action `save()` then `dismiss()`. Disabled when the entry is
    invalid:
    - Feed: `!model.isValid`.
    - Tag: trimmed name is empty.
- Use `@Environment(\.dismiss)`.

**Edit mode:** completely unchanged — `.onDisappear { save() }`, no toolbar buttons.

The existing `save()` methods already do the right thing (insert new on valid, no-op
on invalid). In create mode `save()` only runs from the checkmark, which is disabled
unless valid, so the guard is belt-and-suspenders.

### Parent views

**`FeedsView`** and **`TagsView`**: replace the `+` `NavigationLink` in the toolbar
with a `Button` that toggles a `@State` flag, and present the editor as a sheet:

```swift
@State private var showingCreateFeed = false
// ...
ToolbarItem(placement: .topBarTrailing) {
    Button { showingCreateFeed = true } label: { Image(systemName: "plus") }
}
// ...
.sheet(isPresented: $showingCreateFeed) {
    NavigationStack { FeedEditorView(feed: nil) }
}
```

Same pattern for `TagsView` with `showingCreateTag` and `TagEditorView(tag: nil)`.
The `NavigationStack` inside the sheet provides the nav bar so the editor's title and
toolbar items render.

### Localization

Cancel and checkmark are icons with accessibility labels:
- `"Cancel"` already exists in `Localizable.xcstrings`.
- Add `"Save"` with German `"Speichern"`, marked `"state": "translated"`.

## Testing

This is presentation/SwiftUI wiring with no extractable pure logic, so verification is
by building the app and a manual check:
- `+` on Feeds/Tags opens a sheet.
- Checkmark is disabled until the entry is valid; tapping it inserts and dismisses.
- Cancel and swipe-down dismiss without inserting.
- Editing an existing feed/tag still pushes and auto-saves.

## Files touched

- `Yana/Views/Config/FeedEditorView.swift`
- `Yana/Views/Config/TagEditorView.swift`
- `Yana/Views/Config/FeedsView.swift`
- `Yana/Views/Config/TagsView.swift`
- `Yana/Resources/Localizable.xcstrings`
