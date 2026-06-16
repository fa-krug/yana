# Config Editors: Auto-save & Push Navigation

**Date:** 2026-06-17
**Status:** Approved

## Goal

Remove the explicit Save button from the config-hub editors and make Tags
navigate the same way as Feeds (push, not sheet). After this change both editors
auto-save on exit, with invalid entries discarded.

## Current State

- `ConfigHubView` pushes `FeedsView` and `TagsView` via `NavigationLink` (consistent).
- **Feeds:** `FeedsView` rows / `+` push `FeedEditorView` (a pushed view). Editing
  goes through `FeedEditorModel` (decoupled state); persistence happens only when the
  user taps a `.confirmationAction` **Save** button, gated by `model.isValid`.
- **Tags:** `TagsView` presents `TagEditorView` as a **`.sheet`** (`editingTag` /
  `isCreating` state). `TagEditorView` wraps itself in its own `NavigationStack` and
  has **Cancel** + **Save** toolbar buttons; Save is gated on a non-empty name.

## Design

### 1. Feeds — remove Save button, auto-save on exit

`FeedEditorView` keeps `FeedEditorModel` unchanged. Replace the toolbar Save button
with persistence in `.onDisappear`:

- **New feed (`feed == nil`):** on disappear, if `model.isValid` → create `Feed`,
  `model.apply(to:availableTags:)`, `modelContext.insert`, `modelContext.save`.
  If invalid → do nothing; nothing was ever inserted, so it is naturally discarded.
- **Existing feed:** on disappear, if `model.isValid` → `apply` + `save`. If invalid
  → do not apply; the feed keeps its last valid state. Invalid edits are discarded.
- Remove the `.confirmationAction { Button("Save") ... }` toolbar item.

No live SwiftData binding or snapshot machinery is needed — the existing
model-based approach already isolates edits until apply.

### 2. Tags — push navigation like Feeds, auto-save

`TagsView`:
- Remove `@State editingTag`, `@State isCreating`, and both `.sheet(...)` modifiers.
- Each tag row becomes `NavigationLink { TagEditorView(tag: tag) }` (replacing the
  `Button { editingTag = tag }`).
- The `+` toolbar button becomes `NavigationLink { TagEditorView(tag: nil) } label: { Image(systemName: "plus") }`,
  mirroring `FeedsView`.
- Keep the existing `EditButton`, `onMove` reorder, and delete-confirmation flow
  unchanged.

`TagEditorView`:
- Remove its own `NavigationStack` wrapper (it is now pushed into the hub's stack).
- Remove the Cancel + Save toolbar buttons.
- Persist in `.onDisappear` using the same valid/discard rule:
  - **New tag (`tag == nil`):** if trimmed name non-empty → insert with next
    `sortOrder` (as today). If empty → discard (no insert).
  - **Existing tag:** if trimmed name non-empty → apply rename (skipped for built-in
    Starred) + recolor + save. If the name is empty, persist nothing — the edit
    (including any color change) is discarded, keeping the rule "only persist when
    valid" simple and symmetric with Feeds. Built-in Starred remains recolor-only
    (its name is non-empty and locked, so it always persists).

This makes Tags consistent with Feeds in both navigation and no-save-button behavior.

## Out of Scope

- No change to delete/reorder/search behavior.
- No change to `FeedEditorModel`, `ManagedList`, or `AggregatorOptionsForm`.
- No change to the OPML import/export flow.

## Testing

- Existing tests for feed/tag editing should be updated if they drive the Save
  button. Verify build + test suite passes.
- Manual: create/edit a feed and a tag, navigate back; confirm valid entries persist
  and invalid/empty new entries are discarded.

## Localization

No new user-facing strings are expected (Save/Cancel labels are being removed, not
added). If any new string appears, add `de` translation per project rules.
