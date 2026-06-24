import Foundation

/// One parked warmup payload, keyed by the article identifier and the exact rendered HTML.
/// HTML-string equality is the validity gate: any theme / text-size / summary difference
/// produces a different string and therefore a clean miss — never a stale render.
struct WarmupSlot<Payload> {
    let identifier: String
    let html: String
    let payload: Payload

    /// The payload iff both the identifier and the rendered HTML match.
    func matched(identifier: String, html: String) -> Payload? {
        (self.identifier == identifier && self.html == html) ? payload : nil
    }
}

/// Single-slot holder for a warmup payload. `take` is single-use: a hit clears the slot;
/// a miss leaves it intact for a later attempt. `discardUnused` releases whatever remains.
@MainActor
final class WarmupSlotBox<Payload> {
    private var slot: WarmupSlot<Payload>?

    func store(identifier: String, html: String, payload: Payload) {
        slot = WarmupSlot(identifier: identifier, html: html, payload: payload)
    }

    func take(identifier: String, html: String) -> Payload? {
        guard let payload = slot?.matched(identifier: identifier, html: html) else { return nil }
        slot = nil
        return payload
    }

    func discardUnused() -> Payload? {
        defer { slot = nil }
        return slot?.payload
    }
}
