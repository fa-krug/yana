import Foundation
import Testing
@testable import Yana

struct SyncLogTests {

    @Test func logAppendsChronologicallyWithMonotonicSequence() {
        let log = SyncLog(capacity: 10)
        log.info("first", category: "CloudKit")
        log.error("second", category: "CloudKit")

        let entries = log.snapshot()
        #expect(entries.count == 2)
        #expect(entries[0].message == "first")
        #expect(entries[0].level == .info)
        #expect(entries[1].message == "second")
        #expect(entries[1].level == .error)
        #expect(entries[0].sequence < entries[1].sequence)
        #expect(entries.allSatisfy { $0.source == .app })
        #expect(entries.allSatisfy { $0.category == "CloudKit" })
    }

    @Test func capacityEvictsOldestEntriesFirst() {
        let log = SyncLog(capacity: 3)
        for index in 1...5 { log.info("entry \(index)", category: "Test") }

        let entries = log.snapshot()
        #expect(entries.count == 3)
        #expect(entries.map(\.message) == ["entry 3", "entry 4", "entry 5"])
    }

    @Test func clearRemovesEveryEntry() {
        let log = SyncLog(capacity: 10)
        log.info("gone", category: "Test")
        log.clear()
        #expect(log.snapshot().isEmpty)
    }

    @Test func concurrentWritesLoseNothingAndKeepSequencesUnique() async {
        let log = SyncLog(capacity: 1000)
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for index in 0..<50 { log.info("t\(task)-\(index)", category: "Test") }
                }
            }
        }

        let entries = log.snapshot()
        #expect(entries.count == 400)
        #expect(Set(entries.map(\.sequence)).count == 400)
    }

    @Test func exportTextEmitsOneLinePerEntryWithLevelSourceAndCategory() {
        let entry = SyncLog.Entry(
            sequence: 1,
            date: Date(timeIntervalSince1970: 0),
            level: .error,
            category: "CloudKit",
            message: "export FAILED",
            source: .app
        )

        let text = SyncLog.exportText([entry, entry])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].contains("[error]"))
        #expect(lines[0].contains("[app]"))
        #expect(lines[0].contains("[CloudKit]"))
        #expect(lines[0].contains("export FAILED"))

        // The timestamp is the bracketed first field. Parse it back and compare to `entry.date`
        // instead of re-deriving the exact string `exportText` builds: this fails if the encoded
        // instant is wrong (or unparsable), without hard-coding a calendar date that would only
        // be correct in a positive-UTC-offset timezone, and without simply mirroring
        // `exportText`'s own formatting call back at it.
        #expect(lines[0].hasPrefix("["))
        let stampField = String(lines[0].dropFirst().prefix { $0 != "]" })
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(parser.date(from: stampField) == entry.date)
    }

    @Test func entryIDDisambiguatesSourcesWithTheSameSequence() {
        let app = SyncLog.Entry(sequence: 7, date: Date(), level: .info,
                                category: "c", message: "m", source: .app)
        let system = SyncLog.Entry(sequence: 7, date: Date(), level: .info,
                                   category: "c", message: "m", source: .system)
        #expect(app.id != system.id)
    }
}
