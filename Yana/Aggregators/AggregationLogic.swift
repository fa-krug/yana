import Foundation

/// Pure, side-effect-free orchestration helpers. Easy to unit-test in isolation.
enum AggregationLogic {
    /// Flat per-run cap: fetch up to `dailyLimit` minus what was already collected today.
    /// (Spec decision 2 — the server's adaptive time-of-day quota is intentionally dropped.)
    static func runLimit(dailyLimit: Int, collectedToday: Int) -> Int {
        max(0, dailyLimit - collectedToday)
    }

    /// Intake age filter (spec §2): keep articles whose publish date is no older than
    /// `maxAgeDays`. Unlike the server, the date is NOT rewritten — this only filters.
    static func isWithinIntakeWindow(_ date: Date, now: Date, maxAgeDays: Int = 60) -> Bool {
        date >= now.addingTimeInterval(-Double(maxAgeDays) * 24 * 3600)
    }
}
