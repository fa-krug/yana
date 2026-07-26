# Task 12a Report: Make To-Many Relationships Optional for CloudKit; Enable Mirroring

**Date:** 2026-07-26  
**Status:** DONE  
**Smoke test:** `✔ Test automaticContainerInitializesWithoutThrowing() passed after 0.012 seconds.`  
**Full suite:** `** TEST SUCCEEDED **` — 0 failures

---

## Model Changes

### `Yana/Models/Article.swift`
- `var tags: [Tag] = []` → `var tags: [Tag]?`
- `isStarred`: `tags.contains` → `(tags ?? []).contains`
- `setStarred(_:using:)`: mutate via read-modify-write (`var t = tags ?? []`, append, `tags = t`);
  `removeAll` via filter-and-reassign (`tags = (tags ?? []).filter { !$0.isBuiltIn }`)

### `Yana/Models/Feed.swift`
- `var tags: [Tag] = []` → `var tags: [Tag]?`
- `@Relationship(deleteRule: .cascade, inverse: \Article.feed) var articles: [Article] = []` → `var articles: [Article]?`
  (cascade rule + inverse preserved)

### `Yana/Models/Tag.swift`
- `@Relationship(inverse: \Feed.tags) var feeds: [Feed] = []` → `var feeds: [Feed]?`
- `@Relationship(inverse: \Article.tags) var articles: [Article] = []` → `var articles: [Article]?`

---

## Call-Site Fixes (by file)

### `Yana/Models/ArticleSummary.swift`
- `article.tags.map(\.name)` → `(article.tags ?? []).map(\.name)`

### `Yana/Utilities/TimelineFiltering.swift`
- `Article.filterTagNames`: `tags.map(\.name)` → `(tags ?? []).map(\.name)`

### `Yana/Aggregators/ArticleUpsert.swift`
- `for article in feed.articles` → `for article in feed.articles ?? []`
- `existing.tags = feed.tags` → `existing.tags = feed.tags ?? []`
- Star-preserve after update: `existing.tags.contains` → `!(existing.tags ?? []).contains` + read-modify-write append
- `article.tags = feed.tags` → `article.tags = feed.tags ?? []`
- Star-on-insert: `!article.tags.contains` → `!(article.tags ?? []).contains` + read-modify-write append

### `Yana/Services/LibraryDedup.swift`
- `dedupeFeeds`: `loser.articles` → `loser.articles ?? []`; `loser.tags` → `loser.tags ?? []`; `survivor.tags.contains` → `(survivor.tags ?? []).contains`; append via read-modify-write
- `dedupeTags`: `loser.articles` → `loser.articles ?? []`; `article.tags.contains` → `(article.tags ?? []).contains`; `loser.feeds` → `loser.feeds ?? []`; `feed.tags.contains` → `(feed.tags ?? []).contains`; all appends via read-modify-write
- `dedupeArticles`: `loser.tags` → `(loser.tags ?? [])`; `survivor.tags.contains` → `(survivor.tags ?? []).contains`; append via read-modify-write

### `Yana/Services/FeedPortability.swift`
- `feed.tags.filter` → `(feed.tags ?? []).filter`
- `feed.tags = resolveTags(...)`: assigning `[Tag]` to `[Tag]?` — valid, no change needed

### `Yana/Views/Config/FeedEditorModel.swift`
- `feed.tags.map(\.name)` → `(feed.tags ?? []).map(\.name)` in `init(feed:)`
- `feed.tags = availableTags.filter { ... }`: assigning `[Tag]` to `[Tag]?` — valid, no change needed

### `Yana/Views/Config/FeedsView.swift`
- `feed.articles.count` → `(feed.articles ?? []).count` in delete alert
- `!feed.tags.isEmpty` → `!(feed.tags ?? []).isEmpty`
- `feed.tags.sorted { ... }` → `(feed.tags ?? []).sorted { ... }`

### `Yana/YanaApp.swift`
- Removed BLOCKED comment; changed `cloudKitDatabase: .none` → `.automatic` in production config
- Updated comment to describe the CloudKit model invariants and that they are now enforced by `CloudKitSchemaCompatibilityTests`

---

## Test File Fixes

### `YanaTests/ArticleUpsertTests.swift`
- `feed.articles.count` → `(feed.articles ?? []).count` (×3)
- `feed.articles.first` → `feed.articles?.first` (×2)
- `feed.articles?.first?.tags.map(\.name)` → `feed.articles?.first?.tags?.map(\.name)`
- `article.tags.contains` → `(article.tags ?? []).contains`
- `feed.articles +` → `(feed.articles ?? []) +` for both feeds
- `feed.articles.map` → `(feed.articles ?? []).map` (×2)

### `YanaTests/ArticleSummaryUpsertTests.swift`
- `feed.articles.first?.summary` → `feed.articles?.first?.summary` (×2)
- `feed.articles.count` → `(feed.articles ?? []).count`

### `YanaTests/ArticleSync/PreInsertRecheckTests.swift`
- `feed.articles.first` → `feed.articles?.first` (×3)

### `YanaTests/BackgroundRefreshManagerTests.swift`
- `feed.articles.count` → `(feed.articles ?? []).count` (×2)

### `YanaTests/ModelTests.swift`
- `reloadedTag?.feeds.count` → `(reloadedTag?.feeds ?? []).count`
- `reloadedTag?.feeds.first?.name` → `reloadedTag?.feeds?.first?.name`

### `YanaTests/TagTests.swift`
- `article.tags = feed.tags` → `article.tags = feed.tags ?? []`
- `reloaded?.tags.map(\.name)` → `reloaded?.tags?.map(\.name)`

### `YanaTests/FeedPortabilityTests.swift`
- `restored.tags.map(\.name)` → `(restored.tags ?? []).map(\.name)`

### `YanaTests/FeedEditorModelTests.swift`
- `feed.tags.map(\.name)` → `(feed.tags ?? []).map(\.name)`

### `YanaTests/LibraryDedupTests.swift`
- `a2.tags.append(starred)` → read-modify-write: `var a2Tags = a2.tags ?? []; a2Tags.append(starred); a2.tags = a2Tags`

---

## Mutation Pattern Choices

- **Reads**: `?? []` applied before `.map`, `.filter`, `.contains`, `.sorted`, `for x in`
- **Whole-array assignment** (`[Tag]` → `[Tag]?`): valid Swift, no `?? []` needed at assignment
- **Whole-array assignment with guaranteed non-nil** (snapshot copies like `article.tags = feed.tags`): `?? []` added so the article always has a concrete array
- **Append**: read-modify-write (`var t = x.tags ?? []; t.append(y); x.tags = t`) — never `x.tags?.append()` which would silently no-op on nil
- **Keypaths** (`\.tags` in `relationshipKeyPathsForPrefetching`, `@Relationship(inverse:)`): valid for optional relationships, no change

---

## Verification

1. **Build:** `** BUILD SUCCEEDED **`
2. **Smoke test:** `✔ Test automaticContainerInitializesWithoutThrowing() passed after 0.012 seconds.` — no "relationships be optional" error
3. **Full suite:** `** TEST SUCCEEDED **` — 0 failures across all YanaTests (Swift Testing: ~559 tests) and YanaUITests (3 XCTest UI tests)
