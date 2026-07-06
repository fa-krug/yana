import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — scrapers")
struct AggregatorRegistryScrapersTests {
    private func cfg(_ type: AggregatorType, _ options: AggregatorOptions) -> FeedConfig {
        FeedConfig(type: type, identifier: "x", dailyLimit: 20, options: options, collectedToday: 0)
    }

    @Test func buildsEachScraperType() {
        let r = AggregatorRegistry.shared
        #expect(r.makeAggregator(cfg(.heise, .heise(HeiseOptions())), credentials: .init()) is HeiseAggregator)
        #expect(r.makeAggregator(cfg(.merkur, .merkur(MerkurOptions())), credentials: .init()) is MerkurAggregator)
        #expect(r.makeAggregator(cfg(.tagesschau, .tagesschau(TagesschauOptions())), credentials: .init()) is TagesschauAggregator)
        #expect(r.makeAggregator(cfg(.caschysBlog, .caschysBlog(CaschysBlogOptions())), credentials: .init()) is CaschysBlogAggregator)
        #expect(r.makeAggregator(cfg(.mactechnews, .mactechnews(MactechnewsOptions())), credentials: .init()) is MactechnewsAggregator)
        #expect(r.makeAggregator(cfg(.meinMmo, .meinMmo(MeinMmoOptions())), credentials: .init()) is MeinMmoAggregator)
        #expect(r.makeAggregator(cfg(.theVerge, .theVerge(TheVergeOptions())), credentials: .init()) is TheVergeAggregator)
        #expect(r.makeAggregator(cfg(.arsTechnica, .arsTechnica(ArsTechnicaOptions())), credentials: .init()) is ArsTechnicaAggregator)
    }
}
