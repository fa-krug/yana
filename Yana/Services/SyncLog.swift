import Foundation
import os

/// In-memory diagnostic log for the iCloud/CloudKit sync path, readable inside the app via
/// `SyncLogView` (Settings → Diagnostics).
///
/// Why this exists rather than only `Logger`: SwiftData's CloudKit mirroring logs under
/// `com.apple.coredata` with the interesting values redacted to `<private>`, `OSLogStore` returns
/// only *persisted* entries (most mirroring chatter is debug/info level and therefore absent), and
/// on a locally built Mac Catalyst run `os_log` has produced a complete blackout. This buffer is the
/// one source guaranteed to have data on the device that is failing.
///
/// Concurrency: writes are `nonisolated` and serialised by an unfair lock, because mirroring events
/// arrive on an arbitrary queue in bursts and the adjacent callers (`AggregationWriter`,
/// `LibraryDeduper` — both `@ModelActor`) are off the main actor. The buffer is deliberately **not**
/// `@Observable`: a 200-event export burst would otherwise cause 200 SwiftUI invalidations. Readers
/// poll `snapshot()` instead.
///
/// History is current-launch only — there is no file persistence by design.
final class SyncLog: Sendable {
    static let shared = SyncLog()

    /// Severity, ordered loosely from least to most important. Mirrored onto `Logger` levels.
    enum Level: String, Sendable, CaseIterable, Identifiable {
        case debug, info, notice, error
        var id: String { rawValue }
    }

    /// Where an entry came from: this buffer, or the unified log via `SystemLogReader`.
    enum Source: String, Sendable, CaseIterable, Identifiable {
        case app, system
        var id: String { rawValue }
    }

    struct Entry: Identifiable, Sendable, Equatable {
        /// Monotonic within a source. Combined with `source` to form a collision-free `id`, since
        /// buffer entries and system entries are numbered independently but shown in one list.
        let sequence: UInt64
        let date: Date
        let level: Level
        let category: String
        let message: String
        let source: Source

        var id: String { "\(source.rawValue)-\(sequence)" }
    }

    /// Default retained-entry count. Oldest entries are evicted first.
    static let defaultCapacity = 2000

    private struct Storage {
        var entries: [Entry] = []
        var nextSequence: UInt64 = 1
    }

    private let capacity: Int
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    init(capacity: Int = SyncLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Append an entry. Safe to call from any isolation domain.
    func log(_ level: Level, _ category: String, _ message: String, date: Date = Date()) {
        let entry = storage.withLock { state -> Entry in
            let entry = Entry(
                sequence: state.nextSequence,
                date: date,
                level: level,
                category: category,
                message: message,
                source: .app
            )
            state.nextSequence += 1
            state.entries.append(entry)
            if state.entries.count > capacity {
                state.entries.removeFirst(state.entries.count - capacity)
            }
            return entry
        }
        Self.emitToUnifiedLog(entry)
    }

    func debug(_ message: String, category: String) { log(.debug, category, message) }
    func info(_ message: String, category: String) { log(.info, category, message) }
    func notice(_ message: String, category: String) { log(.notice, category, message) }
    func error(_ message: String, category: String) { log(.error, category, message) }

    /// Chronological snapshot, oldest first.
    func snapshot() -> [Entry] { storage.withLock { $0.entries } }

    func clear() { storage.withLock { $0.entries.removeAll() } }

    /// One line per entry, suitable for the clipboard or a shared `.txt`.
    static func exportText(_ entries: [Entry]) -> String {
        entries.map { entry in
            let stamp = ISO8601DateFormatter.string(
                from: entry.date,
                timeZone: .current,
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            )
            return "[\(stamp)] [\(entry.level.rawValue)] [\(entry.source.rawValue)] [\(entry.category)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    /// Mirror to the unified log so Console and `log stream` still work with a cable attached.
    /// `privacy: .public` on every interpolation is the whole point — redaction is the problem
    /// this feature exists to solve.
    private static func emitToUnifiedLog(_ entry: Entry) {
        let logger = Logger(subsystem: AppConstants.bundleID, category: entry.category)
        switch entry.level {
        case .debug: logger.debug("\(entry.message, privacy: .public)")
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .notice: logger.notice("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        }
    }
}
