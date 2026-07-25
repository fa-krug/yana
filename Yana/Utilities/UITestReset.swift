#if DEBUG
import Foundation
import SwiftData

/// Wipes the local library so a UI test starts from a known-empty state. Triggered by the
/// `-UITEST_RESET_LIBRARY` launch argument.
///
/// Why this is needed: XCTest runs test classes alphabetically against **one** simulator app
/// container, so `ScreenshotUITests` runs before `YanaUITests` and seeds a full fixture library via
/// `ScreenshotSeed` — and that data survives into the next class, because `ScreenshotSeed` is
/// idempotent and bails as soon as any `Feed` exists. Any test asserting on the reader's empty
/// state (or on a short Settings form) therefore has to reset rather than assume a fresh container,
/// otherwise it passes alone and fails in a full run.
enum UITestReset {
    static let launchArgument = "-UITEST_RESET_LIBRARY"

    @MainActor
    static func resetIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        // Articles first: they reference feeds and tags.
        for article in (try? context.fetch(FetchDescriptor<Article>())) ?? [] { context.delete(article) }
        for feed in (try? context.fetch(FetchDescriptor<Feed>())) ?? [] { context.delete(feed) }
        // Built-in tags are re-created by the post-launch `ensureBuiltIns` bootstrap; seeded user
        // tags would otherwise linger in the tag filter and lengthen the Settings form.
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] { context.delete(tag) }
        do {
            try context.save()
        } catch {
            NSLog("UITestReset: save failed: \(error)")
        }
        // Both anchors would now point at articles that no longer exist.
        let settings = AppSettings()
        settings.timelineAnchorIdentifier = nil
        settings.timelineAnchorSyncUID = nil
    }
}
#endif
