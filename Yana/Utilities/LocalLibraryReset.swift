import Foundation
import SwiftData

/// Deletes every locally mirrored `Article`/`Feed`/`Tag` and clears the timeline anchor. Shared by
/// `UITestReset` (DEBUG, launch-argument-gated) and the demo-to-real-server pairing cleanup in
/// `OnboardingServerPage` (release-safe, flag-gated) — see
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md.
enum LocalLibraryReset {
    /// Posted after a wipe. A batch `delete(model:)` does not name the rows it removed in
    /// `ModelContext.didSave`, so `ArticleStore`'s splice never hears about them and kept showing
    /// the whole wiped library (under the demo articles seeded after a disconnect) until the next
    /// launch. `ArticleStore` answers this with a full reload.
    static let didWipe = Notification.Name("LocalLibraryReset.didWipe")

    @MainActor
    static func wipe(context: ModelContext, settings: AppSettings = AppSettings()) {
        // A batch `delete(model:)` deletes in place (no fetch, no per-object faulting), unlike
        // fetching every row into memory and calling `context.delete(_:)` in a loop -- on a
        // library with any real number of articles, that loop ran synchronously on the main
        // actor for long enough to visibly freeze the UI mid-transition (reported after "Weiter"
        // / "Vorerst überspringen" on the onboarding server step). Articles first: they reference
        // feeds and tags.
        do {
            try context.delete(model: Article.self)
            try context.delete(model: Feed.self)
            try context.delete(model: Tag.self)
            try context.save()
        } catch {
            NSLog("LocalLibraryReset: save failed: \(error)")
        }
        // The anchor would now point at an article that no longer exists.
        settings.timelineAnchorIdentifier = nil
        settings.timelineAnchorServerID = nil
        // Force a full resync next time — an opaque cursor from the wiped mirror would otherwise
        // resume from a delta and the wiped articles would never come back.
        settings.syncCursor = nil
        // Every image this wiped library referenced (article bodies, feed logos) is now
        // unreferenced -- flag the same gate SyncEngine.pruneOrphanedImages checks, since this
        // bulk delete bypasses the removed/updated counters that would otherwise trip it (review
        // finding: a disconnect or re-pair otherwise never trips the prune, leaking every cached
        // image from the old library indefinitely).
        settings.imagePruneNeeded = true
        NotificationCenter.default.post(name: didWipe, object: context.container)
    }
}
