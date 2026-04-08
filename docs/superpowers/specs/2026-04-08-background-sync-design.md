# Background Sync & Pull-to-Refresh Design

## Overview

Add local persistence via SwiftData, background sync via `BGAppRefreshTask`, foreground auto-sync, and pull-to-refresh to the Yana iOS app. SwiftData becomes the single source of truth, replacing in-memory article/feed storage.

## Decisions

- **Persistence:** SwiftData (replaces in-memory structs as source of truth)
- **Sync scope:** Everything — articles, feeds/groups, and unread counts
- **Background interval:** User-configurable (15m / 30m / 1h / 2h), default 30 minutes
- **Pull-to-refresh:** Article reader view only (no feed list view exists yet)
- **Foreground sync:** Always sync when app becomes active (no throttling)
- **Error handling:** Silent for background/foreground syncs; surface errors for manual pull-to-refresh

## Data Layer — SwiftData Models

Three `@Model` classes:

### PersistentFeedGroup

- `id: String` — e.g. `user/-/label/Tech`
- `label: String`
- `feeds: [PersistentFeed]` — inverse relationship

### PersistentFeed

- `id: String` — e.g. `feed/123`
- `title: String`, `url: String`, `htmlUrl: String`
- `unreadCount: Int`
- `groups: [PersistentFeedGroup]` — many-to-many
- `articles: [PersistentArticle]` — inverse relationship

### PersistentArticle

- `id: String` — the `tag:google.com,2005:reader/item/{hex}` format
- `title: String`, `author: String`, `published: Date`
- `url: String`, `content: String`
- `read: Bool`, `starred: Bool`
- `feedTitle: String`, `feedStreamId: String`, `feedHtmlUrl: String`
- `feed: PersistentFeed?` — relationship back to feed

Existing `Article`, `Feed`, `FeedGroup` structs remain as lightweight value types for API conversion.

The `ModelContainer` is created in `YanaApp` and injected into the environment.

## SyncService

A `@MainActor` class that orchestrates all data fetching and persistence.

**Constructor:** Takes `ModelContext`, `serverURL`, `authToken`.

### Core method: `sync()`

1. Fetch subscriptions → upsert `PersistentFeed` and `PersistentFeedGroup` records
2. Fetch unread counts → update `unreadCount` on each `PersistentFeed`
3. Fetch articles (all unread + recently read) → upsert `PersistentArticle` records, link to feeds
4. Save the model context

### Upsert logic

For each API response item, fetch existing record by `id`. If found, update fields. If not, insert new. Idempotent — safe to call repeatedly.

### Article cleanup

On sync, remove local articles that are both read and older than 30 days. Starred articles are never cleaned up.

### Last sync tracking

Store `lastSyncDate` in `UserDefaults`.

## Background Sync

Uses `BGAppRefreshTask`:

- Task identifier: `de.fa-krug.Yana.background-refresh`
- Registered in `Info-iOS.plist` under `BGTaskSchedulerPermittedIdentifiers`
- Handler registered in `YanaApp.init()`
- Handler creates `SyncService`, calls `sync()`
- After each completed task, schedules the next one at the configured interval
- First task scheduled on app launch (if authenticated)

Managed by a `BackgroundSyncManager` class.

## Foreground Refresh

- Observe `scenePhase` via `@Environment(\.scenePhase)` in `ContentView`
- On transition to `.active`, call `SyncService.sync()`
- No throttling — always sync on foreground

## Pull-to-Refresh

- `.refreshable { }` modifier on the `ScrollView` in `ArticleReaderView`
- Calls `SyncService.sync()` and reloads current article list from SwiftData
- Errors surfaced via `AppState.errorMessage`

## Sync Interval Setting

- `syncInterval` stored in `UserDefaults` (default: 1800 seconds / 30 minutes)
- Options: 15 min, 30 min, 1 hour, 2 hours
- Picker added to `SettingsView`
- Changing interval reschedules the next `BGAppRefreshTask`

## AppState Migration

### Removed from AppState

- `articles: [Article]`, `feeds: [Feed]`, `continuation`, `hasMoreArticles`
- `loadArticles()`, `loadMoreArticles()`

### Kept on AppState

- Auth: `isAuthenticated`, `serverURL`, `authToken`
- UI: `isLoading`, `errorMessage`, `showSettings`, `currentIndex`

### Added to AppState

- `syncService: SyncService?` — created after authentication
- `lastSyncDate: Date?` — from UserDefaults
- `syncInterval: TimeInterval` — backed by UserDefaults, default 1800

### View changes

- `ArticleReaderView` gets articles via `@Query` from SwiftData instead of `appState.articles`
- Article navigation via `currentIndex` stays on `AppState`
- `markCurrentAsReadAndAdvance()` updates SwiftData model directly (optimistic), then fires API call

## File Layout

### New files

- `Yana/Models/PersistentFeed.swift`
- `Yana/Models/PersistentFeedGroup.swift`
- `Yana/Models/PersistentArticle.swift`
- `Yana/Services/SyncService.swift`
- `Yana/Services/BackgroundSyncManager.swift`

### Modified files

- `Yana/YanaApp.swift` — ModelContainer, background task registration
- `Yana/ContentView.swift` — scenePhase observer for foreground sync
- `Yana/Views/ArticleReaderView.swift` — @Query, .refreshable, navigation updates
- `Yana/Views/SettingsView.swift` — sync interval picker
- `Yana/Models/AppState.swift` — remove article/feed storage, add sync properties
- `project.yml` — BGTaskSchedulerPermittedIdentifiers
- `Yana/Resources/Localizable.xcstrings` — new sync interval strings

### Unchanged

- `APIClient.swift`, `KeychainService.swift`, `Article.swift`, `Feed.swift`
