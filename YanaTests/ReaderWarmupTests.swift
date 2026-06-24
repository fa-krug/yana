import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
struct ReaderWarmupTests {

    @Test func slotMatchesOnIdentifierAndHTML() {
        let slot = WarmupSlot(identifier: "a", html: "<p>x</p>", payload: 42)
        #expect(slot.matched(identifier: "a", html: "<p>x</p>") == 42)
    }

    @Test func slotMissesOnIdentifier() {
        let slot = WarmupSlot(identifier: "a", html: "<p>x</p>", payload: 42)
        #expect(slot.matched(identifier: "b", html: "<p>x</p>") == nil)
    }

    @Test func slotMissesOnHTML() {
        let slot = WarmupSlot(identifier: "a", html: "<p>x</p>", payload: 42)
        #expect(slot.matched(identifier: "a", html: "<p>y</p>") == nil)
    }

    @Test func boxTakeReturnsPayloadOnceThenClears() {
        let box = WarmupSlotBox<String>()
        box.store(identifier: "a", html: "h", payload: "view")
        #expect(box.take(identifier: "a", html: "h") == "view")
        #expect(box.take(identifier: "a", html: "h") == nil)   // single-use: cleared after hit
    }

    @Test func boxTakeOnMissRetainsSlot() {
        let box = WarmupSlotBox<String>()
        box.store(identifier: "a", html: "h", payload: "view")
        #expect(box.take(identifier: "b", html: "h") == nil)   // miss
        #expect(box.discardUnused() == "view")                 // slot survived the miss
    }

    @Test func discardUnusedReturnsAndClears() {
        let box = WarmupSlotBox<String>()
        box.store(identifier: "a", html: "h", payload: "view")
        #expect(box.discardUnused() == "view")
        #expect(box.discardUnused() == nil)
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func fetchNewestReturnsMostRecentByCreatedAt() throws {
        let context = try makeContext()
        let older = Article(title: "older", identifier: "old", url: "u1")
        older.createdAt = Date(timeIntervalSince1970: 100)
        let newer = Article(title: "newer", identifier: "new", url: "u2")
        newer.createdAt = Date(timeIntervalSince1970: 200)
        context.insert(older); context.insert(newer)
        try context.save()
        #expect(ArticleResolution.fetchNewest(in: context)?.identifier == "new")
    }

    @Test func fetchNewestReturnsNilWhenEmpty() throws {
        let context = try makeContext()
        #expect(ArticleResolution.fetchNewest(in: context) == nil)
    }
}
