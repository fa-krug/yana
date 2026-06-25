# Cold-start: SwiftData Indexes + Deferred Tag Bootstrap

**Date:** 2026-06-25
**Status:** Approved

## Problem

After the anchor WebKit warmup shipped, cold start still feels slow. Two grounded
costs remain on or near the launch critical path:

1. **No SwiftData indexes on `Article`.** Every cold-path fetch — the anchor-window
   slice (`ArticleSummaryLoader.loadWindow`), `ArticleResolution.fetchByIdentifier`,
   `ArticleResolution.fetchNewest`, and the full light-index `ArticleStore.fullLoad` —
   filters/sorts by `createdAt` and/or `identifier`. With no index, each is an
   unindexed scan over the entire retained library.

2. **Synchronous tag bootstrap at launch.** `AppDelegate.didFinishLaunchingWithOptions`
   runs `Tag.ensureBuiltIns` (a `Tag` fetch) followed by an **unconditional**
   `mainContext.save()` on every launch, on the launch thread, before returning.

This spec addresses both. (A third idea — a native skeleton overlay — was considered
and deliberately deferred; not in scope here.)

Non-goals: deferring the actual SQLite store open (structurally eager — SwiftUI's
`.modelContainer(AppContainer.shared)` and `@State ArticleStore(container:)` both
require the `ModelContainer` at scene construction); any change to query logic,
retention, or the warmup.

## Design

### 1. Indexes on `Article`

Add the SwiftData `#Index` macro inside the `@Model`:

```swift
@Model
final class Article {
    #Index<Article>([\.createdAt], [\.identifier])
    // …existing properties…
}
```

Two **single-column** indexes:
- `createdAt` — backs the descending/ascending sort in `loadWindow`, `fullLoad`, and
  `fetchNewest`, plus the `>= anchorDate` / `< anchorDate` window predicates.
- `identifier` — backs the one-row `fetchByIdentifier` lookup.

No compound index: no query filters on `createdAt` and `identifier` together.

**Migration:** indexes are additive metadata. The project relies on SwiftData
lightweight migration (models use defaulted properties; there is no `VersionedSchema`).
Adding `#Index` does not require a custom migration plan — SwiftData creates the index
on next launch. **Risk to confirm:** an existing on-disk store must still open cleanly
after the schema gains the index (verify by building/running against a pre-existing
store, and by the existing test suite passing).

### 2. Deferred tag bootstrap

`BGTaskScheduler` registration must remain synchronous in
`didFinishLaunchingWithOptions` (Apple requires registration before launch completes),
so `backgroundRefresh.register()` and `backgroundRefresh.schedule()` stay where they
are. Only the tag work changes:

- `Tag.ensureBuiltIns(in:)` becomes `@discardableResult static func … -> Bool`,
  returning `true` when it inserted the built-in Starred tag, `false` otherwise.
- The call and `save()` move out of the synchronous path into a post-launch task, and
  `save()` runs **only** when an insert happened:

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: …) -> Bool {
    backgroundRefresh.register()
    backgroundRefresh.schedule()
    Task { @MainActor in
        let context = AppContainer.shared.mainContext
        if Tag.ensureBuiltIns(in: context) {
            try? context.save()
        }
    }
    return true
}
```

This removes a `Tag` fetch and a context flush from the synchronous launch path, and
eliminates the unconditional per-launch `save()` entirely (it now happens once, on the
first launch, when the tag is actually inserted).

**Behavioral note:** the built-in Starred tag may be absent for a few milliseconds
after launch until the task runs. It is only consulted on a user star action (well
after launch) and by the tag-filter list; transient absence has no functional impact.

## Testing

Swift Testing (`import Testing`), `@MainActor`, in-memory `ModelContainer(for: Feed.self,
Yana.Tag.self, Article.self, configurations:)` with `isStoredInMemoryOnly: true`.

- **`ensureBuiltIns` return value:** on an empty store it returns `true` and the store
  then contains exactly one built-in `Tag`; called again on the same store it returns
  `false` and inserts nothing (count unchanged).
- **Indexes:** no direct unit test asserts index usage (SwiftData exposes no such API).
  Coverage is: the existing ordering/resolution suites still pass (queries return the
  same results), a clean build, and a manual confirmation that a pre-existing store
  opens after the schema change.

No user-facing strings; no `Localizable.xcstrings` changes.

## Files

- **Edit** `Yana/Models/Article.swift` — add the `#Index` macro.
- **Edit** `Yana/Models/Tag.swift` — `ensureBuiltIns` returns `Bool`.
- **Edit** `Yana/YanaApp.swift` — defer tag bootstrap into a post-launch task with a
  conditional save.
- **Edit/Add** `YanaTests/` — test `ensureBuiltIns` return value (extend an existing
  tag/model test file, or add a focused one).
