import Foundation

/// Observable completed/total tracker for a multi-feed update run. Additive telemetry only:
/// the reader reads it to show "Updating N of M…" while feeds upsert incrementally. Single-feed
/// / single-article operations leave it idle (they use the indeterminate spinner instead).
@MainActor
@Observable
final class UpdateProgress {
    private(set) var completed = 0
    private(set) var total = 0

    /// True while a counted multi-feed run is in flight.
    var isActive: Bool { total > 0 }

    /// 0…1 progress; 0 when idle.
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    func start(total: Int) {
        self.total = max(0, total)
        completed = 0
    }

    func advance() {
        guard total > 0 else { return }
        completed = min(completed + 1, total)
    }

    func reset() {
        total = 0
        completed = 0
    }
}
