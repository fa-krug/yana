import Foundation
import SwiftUI

/// Search text, debounced query, matched results, and the filter-sheet flag for the article list
/// sheet (`ArticleListView`). Owned by `AppState` — which outlives the sheet's own presentation
/// cycle — rather than held as the view's local `@State`, so dismissing and reopening the list
/// doesn't discard an in-progress search or force the sheet to repaint from an empty state before
/// the search reruns: it reappears already showing its last query and results.
@MainActor
@Observable
final class ArticleListUIState {
    var searchText = ""
    var debouncedSearch = ""
    var searchResults: [ArticleSummary]?
    var showFilter = false
}

@MainActor
@Observable
final class AppState {
    /// Index into the (filtered) timeline.
    var currentIndex: Int = 0
    var isUpdating = false
    var showWelcome = false
    /// Which `WelcomeView` step `showWelcome` should open on: `.welcome` for first-launch
    /// onboarding, `.server` for the re-pairing flow (a device that completed onboarding once
    /// but has no valid session any more). Set by `ContentView`'s `.onAppear` gate before it
    /// flips `showWelcome`/opens the welcome window.
    var welcomeInitialStep: WelcomeView.Step = .welcome
    var showServerMigrationNotice = false
    var showSettings = false
    var showFilter = false
    var showArticleList = false
    /// True while the device's very first sync (right after pairing) is still running, gating the
    /// reader behind `InitialSyncLoadingView` -- see `InitialSyncGate`. Never true again once
    /// `AppSettings.hasCompletedInitialSync` is set.
    var isPerformingInitialSync = false
    /// Survives across the article list sheet's dismiss/reopen cycle — see `ArticleListUIState`.
    let articleListState = ArticleListUIState()
}
