import Foundation
import SwiftData
import Testing
@testable import Yana

/// Pins the fix for "the current selected article is not updated when I scroll through the
/// articles" on the Mac side: `TimelineModel` previously had no observer for a synced anchor at
/// all, and the write side never pushed outside of the rare scene `.background` event.
///
/// Each test builds its own `TimelineModel` against a private `AppSettings` suite and a private
/// `NotificationCenter` (never `.default`), mirroring `LibraryRevisionTests`, so these run fast and
/// never race real `AppSettings.timelinePositionDidChange` traffic from other suites.
@MainActor
@Suite("TimelineModel synced anchor")
struct TimelineModelTests {
    private func freshSettings() -> AppSettings {
        let suite = "TimelineModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func insertArticle(_ id: String, into context: ModelContext, createdAt: Date) {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        article.createdAt = createdAt
        article.feed = feed
        context.insert(feed); context.insert(article)
    }

    /// Builds a `TimelineModel` already configured and parked on a 3-article timeline (oldest to
    /// newest: a, b, c), plus the `store` and `center` used to drive it further.
    private func makeConfiguredModel(
        settings: AppSettings, center: NotificationCenter
    ) throws -> (model: TimelineModel, store: ArticleStore, center: NotificationCenter) {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("a", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("b", into: context, createdAt: Date(timeIntervalSince1970: 2))
        insertArticle("c", into: context, createdAt: Date(timeIntervalSince1970: 3))
        try context.save()

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-model-test-\(UUID().uuidString).plist")
        let store = ArticleStore(container: container, cache: SummaryIndexCache(fileURL: cacheURL), anchorProvider: { nil })

        let model = TimelineModel(settings: settings, notificationCenter: center)
        model.configure(modelContext: context, store: store)
        return (model, store, center)
    }

    // MARK: - User-driven selection pushes

    @Test func settingSelectionPushesTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()

        var pushed: [String] = []
        model.pushAnchor = { pushed.append($0.timelineAnchorSyncUID ?? "") }

        model.selection = "b"

        #expect(model.selectedSummary?.identifier == "b")
        #expect(pushed.count == 1)
        #expect(settings.timelineAnchorIdentifier == "b")
    }

    @Test func moveSelectionPushesTheAnchor() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        model.currentIndex = 0   // away from the boundary so the move below actually changes the index

        var pushCount = 0
        model.pushAnchor = { _ in pushCount += 1 }

        model.moveSelection(by: 1)

        #expect(model.currentIndex == 1)
        #expect(pushCount == 1)
    }

    @Test func moveSelectionAtBoundaryDoesNotPush() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        // Parked on the newest (last) article by default; moving forward again is a no-op.
        model.currentIndex = model.filteredArticles.count - 1

        var pushCount = 0
        model.pushAnchor = { _ in pushCount += 1 }

        model.moveSelection(by: 1)

        #expect(pushCount == 0)
    }

    // MARK: - Remote-anchor apply: the no-ping-pong guard

    @Test func jumpToSyncedTimelinePositionMovesSelectionWithoutPushing() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()

        var pushCount = 0
        model.pushAnchor = { _ in pushCount += 1 }

        // Simulate a remote device's anchor arriving for article "a".
        settings.timelineAnchorSyncUID = model.filteredArticles.first { $0.identifier == "a" }?.uid
        model.jumpToSyncedTimelinePosition()

        #expect(model.selectedSummary?.identifier == "a")
        #expect(pushCount == 0, "applying a remote anchor must never push, or two open devices would ping-pong forever")
    }

    @Test func remoteAnchorNotificationMovesSelectionWithoutPushing() async throws {
        let settings = freshSettings()
        let center = NotificationCenter()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: center)
        await store.refreshNow()
        model.applyTimeline()

        var pushCount = 0
        model.pushAnchor = { _ in pushCount += 1 }

        settings.timelineAnchorSyncUID = model.filteredArticles.first { $0.identifier == "a" }?.uid
        center.post(name: AppSettings.timelinePositionDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(50))   // observer runs on the main queue, async-dispatched

        #expect(model.selectedSummary?.identifier == "a")
        #expect(pushCount == 0)
    }

    @Test func jumpToSyncedTimelinePositionIgnoresAUIDThatHasNotSyncedYet() async throws {
        let settings = freshSettings()
        let (model, store, _) = try makeConfiguredModel(settings: settings, center: NotificationCenter())
        await store.refreshNow()
        model.applyTimeline()
        let before = model.currentIndex

        settings.timelineAnchorSyncUID = "some-uid-not-in-this-library"
        model.jumpToSyncedTimelinePosition()

        #expect(model.currentIndex == before)
    }
}
