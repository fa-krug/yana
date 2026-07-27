import Foundation
import OSLog

/// Best-effort read of the unified log for CoreData/CloudKit mirroring entries belonging to this
/// process, merged into the diagnostics view alongside `SyncLog`'s own buffer.
///
/// Deliberately a *supplement*, not the primary source. `OSLogStore` returns only **persisted**
/// entries; most mirroring chatter is debug/info level and therefore often absent, and on a locally
/// built Mac Catalyst run this can come back completely empty. `SyncLog` is the guaranteed source —
/// this adds Apple's side of the story where it happens to be available.
enum SystemLogReader {
    /// CoreData's subsystem — where `NSPersistentCloudKitContainer` logs its mirroring activity.
    ///
    /// Only this subsystem is matched, deliberately: `SyncLog` mirrors every buffer entry to
    /// `Logger(subsystem: AppConstants.bundleID)`, so also matching Yana's own subsystem would show
    /// each app entry twice in the merged list.
    static let coreDataSubsystem = "com.apple.coredata"

    /// A deliberately-early lower bound for a fetch: the instant the device last booted, computed
    /// from `systemUptime` (time since boot, not time since this process launched — a genuine
    /// process-start timestamp would need `sysctl(KERN_PROC…)` C interop for no behavioural gain
    /// here). Using boot time instead of true process start only makes the window *wider*, never
    /// narrower, and `OSLogStore(scope: .currentProcessIdentifier)` already restricts results to
    /// this process — so the extra width cannot pull in entries from another process. It only needs
    /// to be early enough to miss nothing from this launch, and boot time always is.
    static let logWindowStart = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)

    /// Fetch mirroring entries logged since `since`.
    ///
    /// `nonisolated async` on purpose: `OSLogStore.getEntries` is synchronous and can take a while,
    /// and a nonisolated async function runs on the concurrent executor rather than the caller's
    /// actor — so calling this from the main actor does not block it.
    nonisolated static func fetch(since: Date) async -> [SyncLog.Entry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", coreDataSubsystem)

            var results: [SyncLog.Entry] = []
            var sequence: UInt64 = 0
            for case let entry as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
                results.append(SyncLog.Entry(
                    sequence: sequence,
                    date: entry.date,
                    level: level(for: entry.level),
                    category: entry.category.isEmpty ? "coredata" : entry.category,
                    message: entry.composedMessage,
                    source: .system
                ))
                sequence += 1
            }
            return results
        } catch {
            // Surface the failure as an entry rather than silently returning nothing — an empty
            // viewer must never leave you guessing whether there was nothing to show or no way to
            // look.
            return [SyncLog.Entry(
                sequence: 0,
                date: Date(),
                level: .error,
                category: "diagnostics",
                message: "Could not read the system log: \(error.localizedDescription)",
                source: .system
            )]
        }
    }

    static func level(for level: OSLogEntryLog.Level) -> SyncLog.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .error, .fault: .error
        case .undefined: .info
        @unknown default: .info
        }
    }
}
