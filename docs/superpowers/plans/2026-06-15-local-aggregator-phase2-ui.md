# Local Aggregator — Phase 2 (Configuration UI) High-Level Plan

> **Status:** High-level roadmap, NOT a bite-sized implementation plan. Feed this into the
> `superpowers:writing-plans` skill (with the spec) to generate the detailed TDD plan when
> Phase 2 begins.
>
> **Spec:** `docs/superpowers/specs/2026-06-15-local-aggregator-design.md`
> **Depends on:** Phase 1 (models + app shell) complete and merged.

**Goal:** Build the configuration hub and the endless-timeline reader on top of the Phase 1
SwiftData foundation — manage feeds and **tags**, edit per-feed typed options, configure
full-parity settings/API keys, and wire the timeline's tag filter, position memory, and
pull-down force-update. **No real aggregation yet** — `AggregationService` is a no-op stub
that Phase 3 fills in.

**Reading model:** there is **no read/unread state**. The home surface is a single endless
timeline of all articles ordered by `date`, swiped in both directions, with the position
remembered across launches. Feeds are organized by **tags** (no groups); **Starred is a
built-in tag**. The timeline is filtered by toggling tags.

**Architecture:** Pure SwiftUI + SwiftData (`@Query`, `@Environment(\.modelContext)`).
Reached from the reader's menu. All writes go through `modelContext`; reads via `@Query`.
The dynamic feed-editor options form is driven by `switch`ing on `AggregatorOptions`.

---

## Phase 1 model revisions (do first)

Phase 1 is merged but unreleased, so these are plain model edits (no user-data migration):

- **Add `Tag` @Model** (`name` unique, `colorHex?`, `isBuiltIn`, `sortOrder`, `createdAt`,
  inverse `feeds` / `articles`). Seed a locked built-in **Starred** tag on first launch (in
  `YanaApp` / container setup). Register `Tag` in the `ModelContainer` schema.
- **Delete `FeedGroup`**; remove `Feed.group`; add `Feed.tags: [Tag]` (many-to-many).
- **`Article`:** remove `read`; remove the `starred` boolean; add `Article.tags: [Tag]`.
  Starred becomes membership of the built-in Starred tag.
- **`AggregatorOptions`:** replace the single `.managed(ManagedOptions)` case with per-scraper
  cases + structs (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`, `caschysBlog`,
  `mactechnews`, `oglaf`, `meinMmo`); add `RedditOptions.minAgeHours` (48, 0–168) and
  `OglafOptions.convertToBase64` (true); drop `FeedContentOptions.fetchFullContent`. Update
  `AggregatorType.defaultOptions` accordingly.
- **`AppSettings`:** expand to full `UserSettings` parity (see Settings task below).
- **`AppState`:** remove the `Scope` enum; hold the timeline anchor + active tag-filter set.

## Components / File Map (proposed)

New views under `Yana/Views/Config/`:

- **`ConfigHubView`** — root `NavigationStack` for the settings sheet; links to Feeds, Tags,
  Settings. Replaces the Phase 1 placeholder `SettingsView`.
- **`FeedsView`** — flat feed list; per row: tag chips, `lastFetchedAt`, error badge, enable
  toggle, per-feed "Update" (stub), article count. Add / swipe-to-delete; "Update all" (stub).
- **`FeedEditorView`** — create/edit a `Feed`: name, `AggregatorType` picker, identifier
  field whose label/keyboard adapts to `identifierKind`, **tag multi-select with inline
  create**, daily limit, enabled toggle, validation (required identifier when
  `identifierKind != .none`).
- **`AggregatorOptionsForm`** — dynamic section that `switch`es on `AggregatorOptions` and
  renders typed controls per case (toggles/steppers/text/pickers), plus the shared `AIOptions`
  block. Bridges enum ↔ form bindings.
- **`TagsView`** — list/add/rename/recolor/delete/reorder `Tag`s (drag to set `sortOrder`).
  The built-in Starred tag is locked (recolor only; no delete/rename).
- **`SettingsScreenView`** — Reddit (id/secret/user-agent/enabled), YouTube (key/enabled) →
  Keychain + `AppSettings`; AI active provider + per-provider enabled/key/model + OpenAI URL +
  AI knobs → `AppSettings`/Keychain; retention window; background interval.
- **`AggregationService` (stub)** — `Yana/Services/AggregationService.swift`:
  `@MainActor` class with `updateAll()`, `update(feed:)`, `update(article:)` that currently
  no-op (set `isUpdating`, touch `lastFetchedAt`) so the UI wires up end-to-end.

Modified:
- **`ArticleReaderView`** — back it with an all-articles `@Query` ordered by `date` desc;
  identity-based position memory (persist/restore the anchor); **pull-down to refresh**
  (calls `update(article:)` + `updateAll()` stubs); **tag filter** sheet (all tags + Untagged,
  toggles, all-on default, OR semantics, persisted); star toggle on the current article;
  menu entry to `ConfigHubView`.
- **`AppState`** — anchor + tag-filter plumbing (see revisions above).
- **`Localizable.xcstrings`** — all new user-facing strings.

## Suggested Task Groupings (each → a TDD task set in the detailed plan)

1. **Model revisions** — add `Tag`, drop `FeedGroup`, retag `Feed`/`Article`, per-scraper
   options, expand `AppSettings`, trim `AppState`. Seed Starred. Test: schema builds, Starred
   seeded once, per-scraper `defaultOptions`, options round-trip Codable.
2. **Config hub shell** — `ConfigHubView` navigation; replace placeholder `SettingsView`;
   reader menu entry. (View-composition; test = build + basic navigation.)
3. **Tags CRUD** — `TagsView` create/rename/recolor/delete/reorder; Starred locked; SwiftData
   writes. Test tag operations and the Starred lock against an in-memory context.
4. **Feed list** — `FeedsView` flat display with tag chips, enable toggle, delete, article
   count. Test query and toggle/delete persistence.
5. **Feed editor + dynamic options** — `FeedEditorView` + `AggregatorOptionsForm` + tag
   multi-select. The enum↔form bridge is the riskiest piece — test it in isolation (set each
   case's fields via the form model, assert the produced `AggregatorOptions`, including the
   per-scraper cases). Validation logic tested as a pure function.
6. **Timeline reader** — all-articles `@Query` ordered by `date`; identity-based position
   memory; star toggle; pull-down refresh wired to the stub. Test anchor persistence/restore
   and "new articles don't move the anchor".
7. **Tag filter** — filter sheet (all tags + Untagged, toggles, all-on default); apply OR
   semantics to the timeline; persist the active set; snap anchor to nearest visible when
   filtered out. Test filter→predicate mapping (incl. Untagged) and persistence.
8. **Settings screen** — Reddit/YouTube + AI provider config + knobs to Keychain/AppSettings;
   iOS-maintained model lists. Test binding round-trips (reuse Phase 1 Keychain/AppSettings
   helpers; cover the new fields).
9. **AggregationService stub** — define the public API the UI calls; no-op bodies; mark
   `lastFetchedAt`. Test that `updateAll()` flips `isUpdating` and clears it.

## Key Decisions / Open Questions (resolve during detailed planning)

- **Enum↔form binding strategy:** likely an `@Observable` editor view-model holding the
  decomposed fields, producing an `AggregatorOptions` on save (avoids deep `Binding` into
  enum associated values). Decide concretely in the detailed plan.
- **Anchor identity:** persist the current article's `identifier` + `date` (or
  `PersistentIdentifier`) and resolve on launch; define the fallback when it's gone/filtered.
- **Dynamic `@Query` predicate** from the active tag filter: a computed
  `FetchDescriptor`/predicate rebuilt when the filter changes (SwiftData `@Query` with a
  dynamic predicate via init). Untagged = `tags.isEmpty`.
- **Tag filter persistence:** store the set of *disabled* tag identifiers in `AppSettings`
  (default empty = all on), so it survives launches and tolerates tag deletion.
- **iPad:** stay single-surface (timeline home) per spec; no split view this phase.

## Out of Scope (Phase 3)

Concrete aggregators, real network fetching/parsing, AI post-processing, tag snapshotting at
import, dedup/upsert, daily-limit enforcement, age-based retention cleanup, background
refresh. The stub `AggregationService` is the seam they plug into.
