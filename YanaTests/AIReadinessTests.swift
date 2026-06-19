import Testing
@testable import Yana

@MainActor
@Suite("AIReadiness")
struct AIReadinessTests {
    @Test func noneIsNeverReady() {
        #expect(AIReadiness.isReady(provider: .none, loadKey: { _ in "k" }, appleAvailability: { .available }) == false)
    }

    @Test func cloudProviderReadyOnlyWithKey() {
        #expect(AIReadiness.isReady(provider: .openai, loadKey: { _ in "sk-123" }, appleAvailability: { .deviceNotEligible }) == true)
        #expect(AIReadiness.isReady(provider: .openai, loadKey: { _ in "" }, appleAvailability: { .available }) == false)
        #expect(AIReadiness.isReady(provider: .openai, loadKey: { _ in nil }, appleAvailability: { .available }) == false)
    }

    @Test func appleIntelligenceReadyOnlyWhenAvailable() {
        #expect(AIReadiness.isReady(provider: .appleIntelligence, loadKey: { _ in nil }, appleAvailability: { .available }) == true)
        #expect(AIReadiness.isReady(provider: .appleIntelligence, loadKey: { _ in nil }, appleAvailability: { .notEnabled }) == false)
    }
}
