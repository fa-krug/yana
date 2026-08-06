import Foundation

/// Pure check for whether the Welcome/pairing flow needs to be presented, and at which step.
/// Shared by `ContentView` (initial launch) and the server-migration notice's dismiss handlers
/// (iOS `fullScreenCover` and `ServerMigrationNoticeWindowRoot` on Mac) so Welcome is never
/// evaluated/presented at the same time as the migration notice — see
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md.
///
/// `hasSkippedServerPairing` distinguishes "chose demo mode on purpose" (see
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md) from "was paired and the session
/// was revoked" — only the latter forces the device back into the `.server` step on every launch.
enum WelcomeGate {
    static func neededStep(
        hasCompletedOnboarding: Bool,
        isPaired: Bool,
        hasSkippedServerPairing: Bool
    ) -> WelcomeView.Step? {
        if !hasCompletedOnboarding { return .welcome }
        if !isPaired && !hasSkippedServerPairing { return .server }
        return nil
    }
}
