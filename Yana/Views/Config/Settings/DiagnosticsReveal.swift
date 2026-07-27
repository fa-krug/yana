import Foundation

/// The "tap the version row five times" gesture that reveals the diagnostics log.
///
/// The log ships in release builds — it is the only way to see why sync fails on a TestFlight or App
/// Store build talking to the Production CloudKit environment — but it is not a feature users need,
/// so it stays out of the way until asked for. Pure state machine, so the timing rules are tested
/// without a UI.
enum DiagnosticsReveal {
    static let requiredTaps = 5
    static let window: TimeInterval = 3

    struct State: Equatable {
        var firstTapAt: Date?
        var count: Int = 0
    }

    /// Fold a tap at `now` into `state`. Returns the new state and whether the gesture completed.
    /// A tap more than `window` seconds after the first restarts the count at 1. Once the gesture has
    /// unlocked, a further tap within the window keeps returning `unlocked: true` with a climbing
    /// count — the caller is expected to reset `state` once the gesture fires.
    static func register(_ state: State, at now: Date) -> (state: State, unlocked: Bool) {
        guard let firstTapAt = state.firstTapAt,
              now.timeIntervalSince(firstTapAt) <= window
        else {
            return (State(firstTapAt: now, count: 1), false)
        }

        let count = state.count + 1
        return (State(firstTapAt: firstTapAt, count: count), count >= requiredTaps)
    }
}
