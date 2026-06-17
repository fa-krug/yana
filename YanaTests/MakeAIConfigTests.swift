import Foundation
import Testing
@testable import Yana

@MainActor
struct MakeAIConfigTests {
    @Test func appleIntelligenceConfigHasNoKeyOrModel() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ai-test")!)
        settings.activeAIProvider = .appleIntelligence
        let config = AggregationService.makeAIConfig(settings: settings, loadKey: { _ in "should-not-be-read" })
        #expect(config.provider == .appleIntelligence)
        #expect(config.model.isEmpty)
        #expect(config.apiKey.isEmpty)   // keyItem is nil → loadKey never consulted
    }
}
