import Foundation
import SwiftData
import Testing
@testable import Yana

/// A `ConfigStore` test double. Holds an optional document, records save calls, and can be
/// primed to throw `.conflict` on the first save then succeed thereafter.
@MainActor
final class FakeConfigStore: ConfigStore {
    var document: ConfigDocument?
    private(set) var savedDocuments: [ConfigDocument] = []
    private(set) var fetchCount = 0
    private(set) var sawConflict = false

    /// When true, the next save throws `.conflict` (consumed once).
    var throwConflictOnNextSave = false

    func fetch() async throws -> ConfigDocument? {
        fetchCount += 1
        return document
    }

    func save(_ document: ConfigDocument) async throws {
        if throwConflictOnNextSave {
            throwConflictOnNextSave = false
            sawConflict = true
            throw ConfigStoreError.conflict
        }
        self.document = document
        savedDocuments.append(document)
    }
}

/// Counts how many times a store factory is invoked, so tests can assert the CloudKit store is
/// built lazily (and never at all when sync is off).
@MainActor
final class StoreBuildCounter {
    private(set) var count = 0
    func makeStore() -> ConfigStore {
        count += 1
        return FakeConfigStore()
    }
}

@MainActor
@Suite("ConfigSyncService")
struct ConfigSyncServiceTests {
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "ConfigSyncServiceTests.\(UUID().uuidString)")!
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeService(
        store: FakeConfigStore,
        context: ModelContext,
        enabled: Bool = true
    ) -> (ConfigSyncService, AppSettings, UserDefaults) {
        let settingsDefaults = makeSuite()
        let syncDefaults = makeSuite()
        let settings = AppSettings(defaults: settingsDefaults)
        settings.iCloudSyncEnabled = enabled
        let service = ConfigSyncService(
            store: store,
            context: context,
            settings: settings,
            defaults: syncDefaults
        )
        return (service, settings, syncDefaults)
    }

    /// Like `makeService`, but wires the store through a `StoreBuildCounter` factory so a test can
    /// observe whether/when the store is constructed. The `@autoclosure` store argument means the
    /// factory only runs on first actual store access.
    private func makeCountingService(
        counter: StoreBuildCounter,
        context: ModelContext,
        enabled: Bool
    ) -> (ConfigSyncService, AppSettings, UserDefaults) {
        let settingsDefaults = makeSuite()
        let syncDefaults = makeSuite()
        let settings = AppSettings(defaults: settingsDefaults)
        settings.iCloudSyncEnabled = enabled
        let service = ConfigSyncService(
            store: counter.makeStore(),
            context: context,
            settings: settings,
            defaults: syncDefaults
        )
        return (service, settings, syncDefaults)
    }

    @discardableResult
    private func makeFeed(
        _ identifier: String,
        type: AggregatorType = .feedContent,
        in context: ModelContext
    ) -> Feed {
        let feed = Feed(name: identifier, aggregatorType: type, identifier: identifier)
        context.insert(feed)
        try? context.save()
        return feed
    }

    private func feedIdentifiers(in context: ModelContext) -> Set<String> {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        return Set(feeds.map(\.identifier))
    }

    // MARK: - Disabled gate

    @Test func disabledGateDoesNothing() async throws {
        let context = try makeContext()
        let store = FakeConfigStore()
        store.document = ConfigDocument(opml: OPMLCodec.encode([]), settingsData: Data())
        let (service, _, _) = makeService(store: store, context: context, enabled: false)

        await service.push()
        await service.pull()

        #expect(store.savedDocuments.isEmpty)
        #expect(store.fetchCount == 0)
    }

    /// The store (and, in production, its `CKContainer`) must not be constructed at all when sync is
    /// disabled — that CloudKit init is unconditional launch cost for a default-off feature. Every
    /// sync entry point is gated on `iCloudSyncEnabled`, so with sync off none of them may touch it.
    @Test func disabledSyncNeverConstructsStore() async throws {
        let context = try makeContext()
        let builds = StoreBuildCounter()
        let (service, _, _) = makeCountingService(counter: builds, context: context, enabled: false)

        service.requestPush()
        await service.push()
        await service.pull()
        await service.start()

        #expect(builds.count == 0)
    }

    /// With sync enabled the store is built lazily on first use and reused (constructed exactly once).
    @Test func enabledSyncConstructsStoreOnceLazily() async throws {
        let context = try makeContext()
        let builds = StoreBuildCounter()
        let (service, _, _) = makeCountingService(counter: builds, context: context, enabled: true)

        #expect(builds.count == 0) // not built just by constructing the service
        await service.pull()
        #expect(builds.count == 1) // built on first use
        await service.pull()
        #expect(builds.count == 1) // reused, not rebuilt
    }

    // MARK: - Push builds a faithful document

    @Test func pushBuildsFaithfulDocument() async throws {
        let context = try makeContext()
        makeFeed("https://a.example/feed", in: context)
        makeFeed("https://b.example/feed", in: context)

        let store = FakeConfigStore()
        let (service, settings, _) = makeService(store: store, context: context)

        // A synced setting.
        settings.retentionDays = 99

        await service.push()

        #expect(store.savedDocuments.count == 1)
        let doc = try #require(store.savedDocuments.first)

        // OPML round-trips the feeds.
        let decodedIDs = Set(OPMLCodec.decode(doc.opml).map(\.identifier))
        #expect(decodedIDs == ["https://a.example/feed", "https://b.example/feed"])

        // Settings decode to the set value.
        let synced = try #require(try? JSONDecoder().decode(AppSettings.SyncedSettings.self, from: doc.settingsData))
        #expect(synced.retentionDays == 99)
    }

    // MARK: - Pull adds a feed

    @Test func pullAddsFeed() async throws {
        let context = try makeContext()
        let store = FakeConfigStore()
        let opml = OPMLCodec.encode([
            OPMLFeed(name: "New", identifier: "https://new.example/feed", aggregatorType: "feed_content",
                     optionsJSONBase64: "", tags: [], dailyLimit: nil, enabled: true)
        ])
        store.document = ConfigDocument(opml: opml, settingsData: Data())
        let (service, _, _) = makeService(store: store, context: context)

        #expect(feedIdentifiers(in: context).isEmpty)
        await service.pull()
        #expect(feedIdentifiers(in: context).contains("https://new.example/feed"))
    }

    // MARK: - Deletion reconcile

    @Test func deletionReconcileRemovesGoneButKeepsLocalAdditions() async throws {
        let context = try makeContext()
        makeFeed("A", in: context)
        makeFeed("B", in: context)
        makeFeed("C", in: context) // purely-local, never synced

        let store = FakeConfigStore()
        let (service, _, syncDefaults) = makeService(store: store, context: context)

        // Prime last-synced snapshot to {A, B}.
        syncDefaults.set(["A|feed_content", "B|feed_content"], forKey: "sync.lastFeedKeys")

        // Incoming doc contains only A.
        let opml = OPMLCodec.encode([
            OPMLFeed(name: "A", identifier: "A", aggregatorType: "feed_content",
                     optionsJSONBase64: "", tags: [], dailyLimit: nil, enabled: true)
        ])
        store.document = ConfigDocument(opml: opml, settingsData: Data())

        await service.pull()

        let ids = feedIdentifiers(in: context)
        #expect(ids.contains("A"))
        #expect(!ids.contains("B")) // deleted (was synced, now gone)
        #expect(ids.contains("C"))  // preserved (never synced)
    }

    // MARK: - Settings applied on pull

    @Test func settingsAppliedOnPull() async throws {
        let context = try makeContext()
        makeFeed("https://a.example/feed", in: context)

        let store = FakeConfigStore()
        let (service, settings, _) = makeService(store: store, context: context)
        settings.retentionDays = 30

        // Build a settings payload with a changed value.
        var changed = settings.exportSyncedSettings()
        var synced = try #require(try? JSONDecoder().decode(AppSettings.SyncedSettings.self, from: changed))
        synced.retentionDays = 7
        changed = try JSONEncoder().encode(synced)

        let opml = OPMLCodec.encode([
            OPMLFeed(name: "A", identifier: "https://a.example/feed", aggregatorType: "feed_content",
                     optionsJSONBase64: "", tags: [], dailyLimit: nil, enabled: true)
        ])
        store.document = ConfigDocument(opml: opml, settingsData: changed)

        await service.pull()

        #expect(settings.retentionDays == 7)
    }

    // MARK: - Conflict path

    @Test func conflictPathPullsThenSavesOnce() async throws {
        let context = try makeContext()
        makeFeed("A", in: context)

        let store = FakeConfigStore()
        // Prime a remote doc so the pull-after-conflict has something to reconcile.
        store.document = ConfigDocument(
            opml: OPMLCodec.encode([
                OPMLFeed(name: "A", identifier: "A", aggregatorType: "feed_content",
                         optionsJSONBase64: "", tags: [], dailyLimit: nil, enabled: true)
            ]),
            settingsData: Data()
        )
        store.throwConflictOnNextSave = true

        let (service, _, _) = makeService(store: store, context: context)

        await service.push()

        #expect(store.sawConflict)
        // Exactly one successful save recorded (the retry after the conflict).
        #expect(store.savedDocuments.count == 1)
    }
}
