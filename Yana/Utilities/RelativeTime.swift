import Foundation

/// Compact "time since" formatter rendering a single largest unit with a universal,
/// locale-independent symbol and a zero-padded two-digit count — `08s`, `47m`, `03h`, `12d`.
/// The fixed-width token (paired with `.monospacedDigit()`) keeps row widths constant, so
/// list rows never shift as time passes.
enum RelativeTime {
    static func compact(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(format: "%02ds", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%02dm", minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%02dh", hours) }
        return String(format: "%02dd", hours / 24)
    }
}
