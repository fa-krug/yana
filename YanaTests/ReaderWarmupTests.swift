import Testing
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
}
