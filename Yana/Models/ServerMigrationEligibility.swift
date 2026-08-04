import Foundation

/// Pure state-transition logic for the pre-2.0 "Yana now requires a server" notice, kept free of
/// SwiftUI/AppSettings so the rules are directly testable. See
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md.
enum ServerMigrationEligibility {
    struct State: Equatable {
        var hasEvaluated: Bool = false
        var isPreServerMigrationUser: Bool = false
    }

    /// Classifies this device exactly once: a device that had already completed onboarding
    /// before this code ever ran (i.e. under the old, server-free flow) is a "pre-server-migration
    /// user". Once evaluated, later calls are no-ops — a fresh install that finishes onboarding
    /// *after* this code shipped must never be reclassified.
    static func evaluate(_ state: State, hasCompletedOnboarding: Bool) -> State {
        guard !state.hasEvaluated else { return state }
        return State(hasEvaluated: true, isPreServerMigrationUser: hasCompletedOnboarding)
    }

    /// Whether the notice should auto-show at launch.
    static func shouldAutoShow(isPreServerMigrationUser: Bool, hasDismissedNotice: Bool) -> Bool {
        isPreServerMigrationUser && !hasDismissedNotice
    }

    /// Whether the Settings → About "Server Update Notice" restore row should be shown.
    static func canRestore(isPreServerMigrationUser: Bool) -> Bool {
        isPreServerMigrationUser
    }
}
