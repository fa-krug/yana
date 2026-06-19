import Foundation

/// Decides whether AI post-processing can actually run right now, based on the active provider:
/// a cloud provider needs a non-empty stored key; Apple Intelligence needs on-device availability.
/// `loadKey` / `appleAvailability` are injectable so the logic stays unit-testable.
enum AIReadiness {
    static func isReady(
        provider: AIProvider,
        loadKey: (KeychainService.APIKeyItem) -> String? = { KeychainService.loadAPIKey(for: $0) },
        appleAvailability: () -> AppleIntelligenceAvailability = { AppleIntelligenceClient().availability }
    ) -> Bool {
        switch provider {
        case .none:
            return false
        case .appleIntelligence:
            return appleAvailability() == .available
        default:
            guard let item = provider.apiKeyItem else { return false }
            return !(loadKey(item) ?? "").isEmpty
        }
    }
}
