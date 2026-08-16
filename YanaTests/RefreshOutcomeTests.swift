import Testing
@testable import Yana

@MainActor
struct RefreshOutcomeTests {
    @Test func zeroCountAllFeeds() {
        #expect(RefreshOutcome.message(newCount: 0, feedName: nil) == String(localized: "No new articles."))
    }

    // Build the expectation from the same catalog key `RefreshOutcome` uses, rather than a
    // hardcoded English string, so this stays locale-independent on a non-English simulator while
    // still verifying the singular/plural selection and the message format.
    @Test func singularCount() {
        #expect(RefreshOutcome.message(newCount: 1, feedName: nil)
            == String(localized: "Added \(1) new articles."))
    }

    @Test func pluralCount() {
        #expect(RefreshOutcome.message(newCount: 3, feedName: nil)
            == String(localized: "Added \(3) new articles."))
    }

    @Test func namedFeedAppendsSource() {
        let msg = RefreshOutcome.message(newCount: 2, feedName: "Heise")
        #expect(msg.contains("Heise"))
    }
}
