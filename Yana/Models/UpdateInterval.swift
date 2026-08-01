import Foundation

/// How often this device aggregates in the background. `.off` disables background aggregation
/// entirely, and with it retention cleanup — the library then only changes when the user updates by
/// hand.
enum UpdateInterval: String, CaseIterable, Identifiable, Sendable {
    case off, min30, min60, hour2, hour4, hour8, hour24

    var id: String { rawValue }

    /// Interval in seconds, or nil for `.off`.
    var seconds: TimeInterval? {
        switch self {
        case .off:    return nil
        case .min30:  return 1800
        case .min60:  return 3600
        case .hour2:  return 7200
        case .hour4:  return 14400
        case .hour8:  return 28800
        case .hour24: return 86400
        }
    }

    var localizedLabel: String {
        switch self {
        case .off:    return String(localized: "No updates")
        case .min30:  return String(localized: "Every 30 minutes")
        case .min60:  return String(localized: "Every hour")
        case .hour2:  return String(localized: "Every 2 hours")
        case .hour4:  return String(localized: "Every 4 hours")
        case .hour8:  return String(localized: "Every 8 hours")
        case .hour24: return String(localized: "Every 24 hours")
        }
    }

    /// Map a legacy `backgroundInterval` (seconds) to the nearest non-`.off` case (a positive legacy
    /// value always meant "refresh", so it never collapses to `.off`).
    static func nearest(toSeconds seconds: TimeInterval) -> UpdateInterval {
        let candidates: [UpdateInterval] = [.min30, .min60, .hour2, .hour4, .hour8, .hour24]
        let target = seconds > 0 ? seconds : 1800
        return candidates.min(by: {
            let distA = abs(($0.seconds ?? 0) - target)
            let distB = abs(($1.seconds ?? 0) - target)
            if distA == distB {
                return ($0.seconds ?? 0) > ($1.seconds ?? 0)
            }
            return distA < distB
        }) ?? .min60
    }
}
