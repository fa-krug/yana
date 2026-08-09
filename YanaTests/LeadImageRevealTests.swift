import Testing
@testable import Yana

// Pins the fix for the "article stays black on bad internet" bug: the lead-image reveal gate used
// to await the image fetch with no bound, so a stalled fetch left the page at opacity(0) forever
// (showing nothing but .systemBackground, which is black in Dark Mode). `awaitFirst` races the
// load against a timeout so the page always reveals, whichever wins.
@Suite("LeadImageReveal")
struct LeadImageRevealTests {

    @Test func returnsAssoonAsLoadFinishesWhenFasterThanTheTimeout() async {
        let start = ContinuousClock.now
        await LeadImageReveal.awaitFirst(timeout: .seconds(10)) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func returnsAtTheTimeoutWhenTheLoadStalls() async {
        let start = ContinuousClock.now
        await LeadImageReveal.awaitFirst(timeout: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(10))
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed >= .milliseconds(50))
        #expect(elapsed < .seconds(2))
    }
}
