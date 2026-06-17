import Testing
@testable import Yana

@MainActor
struct AIProviderTests {
    @Test func appleIntelligenceHasNoModelsAndBrandName() {
        #expect(AIProvider.appleIntelligence.models.isEmpty)
        #expect(AIProvider.appleIntelligence.displayName == "Apple Intelligence")
        #expect(AIProvider.allCases.contains(.appleIntelligence))
    }
}
