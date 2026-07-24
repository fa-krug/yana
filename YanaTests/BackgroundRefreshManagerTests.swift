import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("BackgroundRefreshManager")
struct BackgroundRefreshManagerTests {
    @Test func nextBeginDateAddsIntervalToReference() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let result = BackgroundRefreshManager.nextBeginDate(from: now, interval: 1800)
        #expect(result == now.addingTimeInterval(1800))
    }

    @Test func nextBeginDateClampsNonPositiveIntervalToMinimum() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Zero or negative intervals would let iOS run immediately/never; clamp to the floor.
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: 0)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: -500)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Fake aggregator returning one canned article (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }

    @Test func runRefreshAwaitsUpdateAllAndImports() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)

        let article = AggregatedArticle(
            title: "x1", identifier: "x1", url: "x1",
            rawContent: "", content: "c", date: .now, author: "", iconURL: nil
        )
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [article])
        }

        await BackgroundRefreshManager.runRefresh(service: service)

        #expect(service.isUpdating == false)
        #expect(feed.articles.count == 1)
    }

    private final class FakeNotifier: Notifying, @unchecked Sendable {
        var authorized: Bool
        var postedCounts: [Int] = []
        init(authorized: Bool) { self.authorized = authorized }
        func requestAuthorization() async -> Bool { authorized }
        func isAuthorized() async -> Bool { authorized }
        func postNewArticles(count: Int) async { postedCounts.append(count) }
    }

    private func freshSettings(notificationsEnabled: Bool) -> AppSettings {
        let defaults = UserDefaults(suiteName: "BGRefreshTests.\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        s.notificationsEnabled = notificationsEnabled
        return s
    }

    @Test func postsNotificationWhenEnabledAuthorizedAndNewArticles() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let article = AggregatedArticle(title: "x1", identifier: "x1", url: "x1", rawContent: "", content: "c", date: .now, author: "", iconURL: nil)
        let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: [article]) }
        let notifier = FakeNotifier(authorized: true)

        await BackgroundRefreshManager.runRefresh(service: service, notifier: notifier, settings: freshSettings(notificationsEnabled: true))

        #expect(notifier.postedCounts == [1])
    }

    @Test func doesNotNotifyWhenDisabled() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let article = AggregatedArticle(title: "x1", identifier: "x1", url: "x1", rawContent: "", content: "c", date: .now, author: "", iconURL: nil)
        let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: [article]) }
        let notifier = FakeNotifier(authorized: true)

        await BackgroundRefreshManager.runRefresh(service: service, notifier: notifier, settings: freshSettings(notificationsEnabled: false))

        #expect(notifier.postedCounts.isEmpty)
        #expect(feed.articles.count == 1)
    }

    @Test func doesNotNotifyWhenNotAuthorized() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let article = AggregatedArticle(title: "x1", identifier: "x1", url: "x1", rawContent: "", content: "c", date: .now, author: "", iconURL: nil)
        let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: [article]) }
        let notifier = FakeNotifier(authorized: false)

        await BackgroundRefreshManager.runRefresh(service: service, notifier: notifier, settings: freshSettings(notificationsEnabled: true))

        #expect(notifier.postedCounts.isEmpty)
    }

    @Test("schedule() no-ops on a passive device (interval provider never consulted)")
    func passiveScheduleNoOps() throws {
        let container = try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var intervalAsked = false
        let passive = BackgroundRefreshManager(
            container: container,
            intervalProvider: { intervalAsked = true; return 300 },
            now: { Date(timeIntervalSince1970: 0) },
            isPassive: { true })
        passive.schedule()
        #expect(intervalAsked == false)      // guard returned before consulting the interval

        // Sanity: with isPassive false the guard passes and the interval IS consulted.
        var activeAsked = false
        let active = BackgroundRefreshManager(
            container: container,
            intervalProvider: { activeAsked = true; return 300 },
            now: { Date(timeIntervalSince1970: 0) },
            isPassive: { false })
        active.schedule()
        #expect(activeAsked == true)
    }
}
