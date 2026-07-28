import Foundation

/// Measures how long the main actor goes unresponsive while some work runs — the thing a user
/// perceives as "the UI lags". Ticks on the main actor every 2 ms and reports the worst gap.
///
/// Used by the regression tests that pin SwiftData work to a background thread. A gap is the only
/// observable that distinguishes "the fetch ran on a background thread" from "the fetch ran on the
/// main thread": both take the same wall-clock time, but only the latter freezes the UI.
@MainActor
final class MainActorResponsiveness {
    private var stamps: [Date] = []
    private var ticker: Task<Void, Never>?

    /// Longest observed gap between main-actor ticks, in milliseconds.
    private(set) var maxGapMS: Double = 0
    /// Ticks actually recorded — near zero over a long window means the main actor never ran.
    private(set) var tickCount = 0

    func start() {
        stamps = [Date()]
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                stamps.append(Date())
            }
        }
    }

    /// Stop ticking and compute the worst gap. A gap that spans the whole measured window (i.e. no
    /// ticks at all) is reported as the full window, so a total block can't read as "no gap".
    @discardableResult
    func stop() -> Double {
        ticker?.cancel()
        ticker = nil
        tickCount = max(0, stamps.count - 1)
        guard let first = stamps.first, let last = stamps.last else { return 0 }
        maxGapMS = 0
        for i in 1..<max(stamps.count, 1) {
            maxGapMS = max(maxGapMS, stamps[i].timeIntervalSince(stamps[i - 1]) * 1000)
        }
        if tickCount == 0 { maxGapMS = last.timeIntervalSince(first) * 1000 }
        return maxGapMS
    }

    /// Run `body` (on the main actor) and return the worst main-actor gap observed while it ran.
    static func measuring(_ body: () async -> Void) async -> Double {
        let probe = MainActorResponsiveness()
        probe.start()
        // Let the ticker take its first tick so a subsequent block registers as a gap.
        try? await Task.sleep(for: .milliseconds(20))
        await body()
        try? await Task.sleep(for: .milliseconds(20))
        return probe.stop()
    }
}
