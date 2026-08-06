import Foundation

/// Pure check for whether the Welcome/pairing flow needs to be presented, and at which step.
/// Shared by `ContentView` (initial launch) and the server-migration notice's dismiss handlers
/// (iOS `fullScreenCover` and `ServerMigrationNoticeWindowRoot` on Mac) so Welcome is never
/// evaluated/presented at the same time as the migration notice — see
/// docs/superpowers/specs/2026-08-06-existing-user-notice-design.md.
enum WelcomeGate {
    static func neededStep(hasCompletedOnboarding: Bool, isPaired: Bool) -> WelcomeView.Step? {
        if !hasCompletedOnboarding { return .welcome }
        if !isPaired { return .server }
        return nil
    }
}
