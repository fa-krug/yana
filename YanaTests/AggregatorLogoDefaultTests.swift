import Foundation
import Testing
@testable import Yana

@Suite("Aggregator.logoImageURL default")
struct AggregatorLogoDefaultTests {
    private struct PlainAggregator: Aggregator {
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { [] }
    }

    @Test func defaultsToNil() async {
        let value = await PlainAggregator().logoImageURL()
        #expect(value == nil)
    }
}
