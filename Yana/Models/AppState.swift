import Foundation
import SwiftUI

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
}
