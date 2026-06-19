import Testing
@testable import Yana

@MainActor
struct RefreshOutcomeTests {
    @Test func zeroCountAllFeeds() {
        #expect(RefreshOutcome.message(newCount: 0, feedName: nil) == String(localized: "No new articles."))
    }

    // Build the expectation from the same catalog keys `RefreshOutcome` uses, rather than a
    // hardcoded English string. A literal like "Added 1 new article." is not a catalog key, so on
    // a non-English simulator it falls back to English while `message` returns the translation —
    // a spurious mismatch. Reconstructing via the real keys keeps the assertion locale-independent
    // while still verifying the singular/plural word selection and the message format.
    @Test func singularCount() {
        let word = String(localized: "article")
        #expect(RefreshOutcome.message(newCount: 1, feedName: nil)
            == String(localized: "Added \(1) new \(word)."))
    }

    @Test func pluralCount() {
        let word = String(localized: "articles")
        #expect(RefreshOutcome.message(newCount: 3, feedName: nil)
            == String(localized: "Added \(3) new \(word)."))
    }

    @Test func namedFeedAppendsSource() {
        let msg = RefreshOutcome.message(newCount: 2, feedName: "Heise")
        #expect(msg.contains("Heise"))
    }
}
