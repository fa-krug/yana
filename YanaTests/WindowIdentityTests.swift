import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct WindowIdentityTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self,
            configurations: config
        )
    }

    @Test func feedEditorTargetCreateRoundTrips() throws {
        let data = try JSONEncoder().encode(FeedEditorTarget.create)
        let decoded = try JSONDecoder().decode(FeedEditorTarget.self, from: data)
        #expect(decoded == .create)
    }

    @Test func feedEditorTargetEditDistinguishesFeeds() throws {
        let container = try makeContainer()
        let a = Feed(name: "A", aggregatorType: .feedContent, identifier: "a://")
        let b = Feed(name: "B", aggregatorType: .feedContent, identifier: "b://")
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        try container.mainContext.save()

        #expect(FeedEditorTarget.edit(a.persistentModelID) == .edit(a.persistentModelID))
        #expect(FeedEditorTarget.edit(a.persistentModelID) != .edit(b.persistentModelID))
        #expect(FeedEditorTarget.edit(a.persistentModelID) != .create)
    }

    @Test func settingsPanesAreStableAndOrdered() {
        #expect(SettingsPane.allCases == [.general, .reader, .feeds, .tags, .integrations, .ai, .about])
        #expect(SettingsPane.ai.rawValue == "ai")
    }
}
