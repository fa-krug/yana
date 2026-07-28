import Foundation
import OSLog
import Testing
@testable import Yana

struct SystemLogReaderTests {

    @Test func mapsOSLogLevelsOntoSyncLogLevels() {
        #expect(SystemLogReader.level(for: .debug) == .debug)
        #expect(SystemLogReader.level(for: .info) == .info)
        #expect(SystemLogReader.level(for: .notice) == .notice)
        #expect(SystemLogReader.level(for: .error) == .error)
        #expect(SystemLogReader.level(for: .fault) == .error)
        #expect(SystemLogReader.level(for: .undefined) == .info)
    }

    // MARK: - Empty-fetch wrapping

    /// A successful fetch that found nothing must not silently return `[]` — that's exactly the gap
    /// that makes a launch which really did have a problem (e.g. a mirroring failure that never
    /// posts `eventChangedNotification`) look clean. `wrapped(_:)` is a pure function precisely so
    /// this can be tested without a real `OSLogStore`.
    @Test func emptyResultsAreWrappedInOneExplanatoryEntry() {
        let wrapped = SystemLogReader.wrapped([])
        #expect(wrapped.count == 1)
        #expect(wrapped[0].source == .system)
        #expect(wrapped[0].level == .notice)
        #expect(wrapped[0].message.isEmpty == false)
    }

    @Test func nonEmptyResultsPassThroughUnchanged() {
        let entry = SyncLog.Entry(
            sequence: 0, date: Date(), level: .info, category: "coredata", message: "real entry",
            source: .system
        )
        #expect(SystemLogReader.wrapped([entry]) == [entry])
    }

    @Test func errorEntryReportsTheUnderlyingErrorAndIsMarkedError() {
        struct SampleError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let entry = SystemLogReader.errorEntry(for: SampleError())
        #expect(entry.level == .error)
        #expect(entry.source == .system)
        #expect(entry.message.contains("boom"))
    }
}
