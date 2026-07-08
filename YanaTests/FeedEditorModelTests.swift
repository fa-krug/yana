import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("FeedEditorModel")
struct FeedEditorModelTests {
    @Test func newModelStartsWithDefaultsAndIsInvalidWithoutName() {
        let model = FeedEditorModel(feed: nil)
        #expect(model.name.isEmpty)
        #expect(model.type == .fullWebsite)
        guard case .fullWebsite = model.options else { Issue.record("expected fullWebsite options"); return }
        #expect(model.isValid == false)
        model.name = "Heise"
        model.type = .heise
        model.identifier = "https://heise.de"
        #expect(model.isValid == true)
    }

    @Test func identifierNotRequiredForNoneKind() {
        let model = FeedEditorModel(feed: nil)
        model.name = "Oglaf"
        model.changeType(.oglaf) // identifierKind == .none
        #expect(model.identifier.isEmpty)
        #expect(model.isValid == true)
    }

    @Test func changingTypeResetsOptionsToDefault() {
        let model = FeedEditorModel(feed: nil)
        model.changeType(.reddit)
        guard case .reddit = model.options else { Issue.record("expected reddit options"); return }
        model.changeType(.podcast)
        guard case .podcast = model.options else { Issue.record("expected podcast options"); return }
    }

    @Test func applyWritesFieldsAndMatchedTags() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        let tech = Tag(name: "Tech"); let fun = Tag(name: "Fun")
        context.insert(tech); context.insert(fun)

        let model = FeedEditorModel(feed: nil)
        model.name = "Heise"
        model.changeType(.heise)
        model.identifier = "https://heise.de"
        model.dailyLimit = 5
        model.selectedTagNames = ["Tech"]

        let feed = Feed(name: "", aggregatorType: .feedContent, identifier: "")
        model.apply(to: feed, availableTags: [tech, fun])

        #expect(feed.name == "Heise")
        #expect(feed.type == .heise)
        #expect(feed.dailyLimit == 5)
        #expect(feed.tags.map(\.name) == ["Tech"])
    }
}
