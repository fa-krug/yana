import Foundation
import SwiftData

/// Deletes every locally mirrored `Article`/`Feed`/`Tag` and clears the timeline anchor. Shared by
/// `UITestReset` (DEBUG, launch-argument-gated) and the demo-to-real-server pairing cleanup in
/// `OnboardingServerPage` (release-safe, flag-gated) — see
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md.
enum LocalLibraryReset {
    @MainActor
    static func wipe(context: ModelContext) {
        // Articles first: they reference feeds and tags.
        for article in (try? context.fetch(FetchDescriptor<Article>())) ?? [] { context.delete(article) }
        for feed in (try? context.fetch(FetchDescriptor<Feed>())) ?? [] { context.delete(feed) }
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] { context.delete(tag) }
        do {
            try context.save()
        } catch {
            NSLog("LocalLibraryReset: save failed: \(error)")
        }
        // The anchor would now point at an article that no longer exists.
        AppSettings().timelineAnchorIdentifier = nil
        // Force a full resync next time — an opaque cursor from the wiped mirror would otherwise
        // resume from a delta and the wiped articles would never come back.
        AppSettings().syncCursor = nil
    }
}
