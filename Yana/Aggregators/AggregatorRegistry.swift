import Foundation

/// Maps an `AggregatorType` to a concrete `Aggregator`. Phase 1 registers nothing;
/// Phase 3 fills in concrete factories.
final class AggregatorRegistry: Sendable {
    static let shared = AggregatorRegistry()

    private init() {}

    /// Build an aggregator for the given type, or `nil` if none is registered yet.
    func makeAggregator(
        for type: AggregatorType,
        identifier: String,
        options: AggregatorOptions,
        credentials: AggregatorCredentials = .init()
    ) -> Aggregator? {
        // Phase 3: switch over `type` and return concrete aggregators.
        nil
    }
}
