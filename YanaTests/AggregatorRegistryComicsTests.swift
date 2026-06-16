import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — comics")
struct AggregatorRegistryComicsTests {
    private func cfg(_ type: AggregatorType, _ options: AggregatorOptions) -> FeedConfig {
        FeedConfig(type: type, identifier: "", dailyLimit: 20, options: options, collectedToday: 0)
    }

    @Test func buildsComicAggregators() {
        #expect(AggregatorRegistry.shared.makeAggregator(cfg(.explosm, .explosm(ExplosmOptions())), credentials: .init()) is ExplosmAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(
            cfg(.darkLegacy, .darkLegacy(DarkLegacyOptions())), credentials: .init()) is DarkLegacyAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(cfg(.oglaf, .oglaf(OglafOptions())), credentials: .init()) is OglafAggregator)
    }
}
