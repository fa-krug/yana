# Local Aggregator — Phase 2 (Configuration UI) High-Level Plan

> **Status:** High-level roadmap, NOT a bite-sized implementation plan. Feed this into the
> `superpowers:writing-plans` skill (with the spec) to generate the detailed TDD plan when
> Phase 2 begins.
>
> **Spec:** `docs/superpowers/specs/2026-06-15-local-aggregator-design.md`
> **Depends on:** Phase 1 (models + app shell) complete and merged.

**Goal:** Build the configuration hub on top of the Phase 1 SwiftData foundation — manage
feeds and groups, edit per-feed typed options, browse/filter all articles, configure
settings/API keys, and wire the reader's scope selector and force-update entry points.
**No real aggregation yet** — `AggregationService` is a no-op stub that Phase 3 fills in.

**Architecture:** Pure SwiftUI + SwiftData (`@Query`, `@Environment(\.modelContext)`).
Reached from the reader's gear button. All writes go through `modelContext`; reads via
`@Query`. The dynamic feed-editor options form is driven by `switch`ing on
`AggregatorOptions`.

---

## Components / File Map (proposed)

New views under `Yana/Views/Config/`:

- **`ConfigHubView`** — root `NavigationStack` for the settings sheet; links to Feeds,
  Groups, Article List, Settings. Replaces the Phase 1 placeholder `SettingsView`.
- **`FeedsView`** — feed list grouped by `FeedGroup`; per-row unread count, `lastFetchedAt`,
  error badge, enable toggle, per-feed "Update" (calls stub). Add / swipe-to-delete.
- **`FeedEditorView`** — create/edit a `Feed`: name, `AggregatorType` picker, identifier
  field whose label/keyboard adapts to `identifierKind`, group picker, daily limit,
  enabled toggle, validation (required identifier when `identifierKind != .none`).
- **`AggregatorOptionsForm`** — dynamic section that `switch`es on `AggregatorOptions` and
  renders typed controls per case (toggles/steppers/text), plus the shared `AIOptions`
  block. Bridges enum ↔ form bindings.
- **`GroupsView`** — list/add/rename/delete/reorder `FeedGroup`s (drag to set `sortOrder`);
  reassign feeds.
- **`ArticleListView`** — all articles, filterable by feed/group and read/unread/starred;
  row swipe actions for read/star (and force-update, stubbed); tap selects an article and
  enters the reader at that index; global "Update all" (stub).
- **`SettingsScreenView`** — API keys (Reddit id/secret, YouTube key) → Keychain; AI
  provider + model + knobs → `AppSettings`; retention window; background interval.
- **`AggregationService` (stub)** — `Yana/Services/AggregationService.swift`:
  `@MainActor` class with `updateAll()`, `update(feed:)`, `update(article:)` that currently
  no-op (set `isUpdating`, touch `lastFetchedAt`) so the UI wires up end-to-end.

Modified:
- **`ArticleReaderView`** — add the scope selector (All Unread / Starred / a Feed / a
  Group) that parameterizes the `@Query`; add "Update all" + per-article force-update
  toolbar actions (call stub); menu entry to `ConfigHubView`.
- **`AppState`** — expand `Scope` to include `.feed(PersistentIdentifier)` and
  `.group(PersistentIdentifier)` cases; add selection plumbing for "tap article → reader".
- **`Localizable.xcstrings`** — all new user-facing strings.

## Suggested Task Groupings (each → a TDD task set in the detailed plan)

1. **Config hub shell** — `ConfigHubView` navigation; replace placeholder `SettingsView`;
   reader menu entry. (View-composition; test = build + basic navigation.)
2. **Groups CRUD** — `GroupsView` create/rename/delete/reorder; SwiftData writes. Test
   group operations against an in-memory context.
3. **Feed list** — `FeedsView` grouped display, enable toggle, delete. Test query grouping
   and toggle persistence.
4. **Feed editor + dynamic options** — `FeedEditorView` + `AggregatorOptionsForm`; the
   enum↔form bridge is the riskiest piece, test it in isolation (set each case's fields via
   the form model, assert the produced `AggregatorOptions`). Validation logic tested as a
   pure function.
5. **Article list + filters** — `ArticleListView` with feed/group/read/starred predicates;
   swipe actions for read/star. Test predicate construction and mutations.
6. **Reader scope selector** — expand `AppState.Scope`; parameterize reader `@Query`;
   tap-article-to-reader. Test scope→predicate mapping.
7. **Settings screen** — API keys to Keychain, prefs to `AppSettings`. Test binding
   round-trips (reuse Phase 1 Keychain/AppSettings helpers).
8. **AggregationService stub** — define the public API the UI calls; no-op bodies; mark
   `lastFetchedAt`. Test that `updateAll()` flips `isUpdating` and clears it.

## Key Decisions / Open Questions (resolve during detailed planning)

- **Enum↔form binding strategy:** likely an `@Observable` editor view-model holding the
  decomposed fields, producing an `AggregatorOptions` on save (avoids deep `Binding` into
  enum associated values). Decide concretely in the detailed plan.
- **Scope identity:** use `PersistentIdentifier` (stable) vs. `Feed`/`FeedGroup` object in
  `AppState.Scope`. Lean `PersistentIdentifier` for `Sendable`/`Equatable` cleanliness.
- **Dynamic `@Query` predicate** from runtime scope: a computed `FetchDescriptor`/predicate
  rebuilt when scope changes (SwiftData `@Query` with a dynamic predicate via init).
- **iPad:** stay single-surface (reader home) per spec; no split view this phase.

## Out of Scope (Phase 3)

Concrete aggregators, real network fetching/parsing, AI post-processing, dedup/upsert,
daily-limit enforcement, retention cleanup, background refresh. The stub `AggregationService`
is the seam they plug into.
