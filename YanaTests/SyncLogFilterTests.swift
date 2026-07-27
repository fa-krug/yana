import Foundation
import Testing
@testable import Yana

struct SyncLogFilterTests {

    private func entry(
        _ sequence: UInt64,
        _ level: SyncLog.Level,
        _ category: String,
        _ message: String,
        _ source: SyncLog.Source = .app
    ) -> SyncLog.Entry {
        SyncLog.Entry(sequence: sequence, date: Date(timeIntervalSince1970: TimeInterval(sequence)),
                      level: level, category: category, message: message, source: source)
    }

    private var sample: [SyncLog.Entry] {
        [
            entry(1, .info, "CloudKit", "export succeeded"),
            entry(2, .error, "CloudKit", "export FAILED"),
            entry(3, .info, "Dedup", "Dedup collapsed 3 duplicate row(s)"),
            entry(4, .notice, "coredata", "mirroring started", .system),
        ]
    }

    @Test func emptyFilterReturnsEverythingUnchanged() {
        #expect(SyncLogFilter().apply(to: sample).map(\.sequence) == [1, 2, 3, 4])
    }

    @Test func levelFilterMatchesExactly() {
        var filter = SyncLogFilter()
        filter.level = .error
        #expect(filter.apply(to: sample).map(\.sequence) == [2])
    }

    @Test func sourceFilterSeparatesAppFromSystem() {
        var filter = SyncLogFilter()
        filter.source = .system
        #expect(filter.apply(to: sample).map(\.sequence) == [4])
    }

    @Test func textFilterMatchesMessageOrCategoryCaseInsensitively() {
        var filter = SyncLogFilter()
        filter.text = "DEDUP"
        #expect(filter.apply(to: sample).map(\.sequence) == [3])

        filter.text = "failed"
        #expect(filter.apply(to: sample).map(\.sequence) == [2])

        // Only entry 4's category ("coredata") contains this — its message ("mirroring started")
        // does not — so this exercises the category branch specifically.
        filter.text = "coredata"
        #expect(filter.apply(to: sample).map(\.sequence) == [4])
    }

    @Test func filtersCombineWithAndSemantics() {
        var filter = SyncLogFilter()
        filter.level = .info
        filter.text = "export"
        #expect(filter.apply(to: sample).map(\.sequence) == [1])
    }
}
