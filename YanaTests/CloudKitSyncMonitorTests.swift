import CoreData
import Foundation
import Testing
@testable import Yana

struct CloudKitSyncMonitorTests {

    @Test func describeIncludesDomainCodeAndMessage() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Not Authenticated"]
        )

        let lines = CloudKitSyncMonitor.describe(error)
        #expect(lines.first?.contains("CKErrorDomain") == true)
        #expect(lines.first?.contains("Code=9") == true)
        #expect(lines.first?.contains("Not Authenticated") == true)
    }

    @Test func describeListsUserInfoKeysExceptTheOnesItRecursesInto() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 11,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                "ServerErrorDescription": "record to insert already exists",
            ]
        )

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("[ServerErrorDescription]"))
        #expect(joined.contains("record to insert already exists"))
    }

    @Test func describeRecursesIntoUnderlyingError() {
        let underlying = NSError(domain: "NSCocoaErrorDomain", code: 134400,
                                 userInfo: [NSLocalizedDescriptionKey: "Mirroring unavailable"])
        let error = NSError(domain: "CKErrorDomain", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Internal error",
                                NSUnderlyingErrorKey: underlying,
                            ])

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("Underlying:"))
        #expect(joined.contains("NSCocoaErrorDomain Code=134400"))
        #expect(joined.contains("Mirroring unavailable"))
    }

    @Test func describeRecursesIntoPartialErrors() {
        let partial = NSError(domain: "CKErrorDomain", code: 14,
                              userInfo: [NSLocalizedDescriptionKey: "Server record changed"])
        let error = NSError(domain: "CKErrorDomain", code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Partial failure",
                                "CKPartialErrors": ["Article-42": partial],
                            ])

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("PartialError for Article-42:"))
        #expect(joined.contains("CKErrorDomain Code=14"))
        #expect(joined.contains("Server record changed"))
    }

    @Test func describeIndentsNestedLevels() throws {
        let underlying = NSError(domain: "Inner", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "inner"])
        let error = NSError(domain: "Outer", code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "outer",
                                NSUnderlyingErrorKey: underlying,
                            ])

        let lines = CloudKitSyncMonitor.describe(error)
        let innerLine = try #require(lines.first { $0.contains("Inner Code=1") })
        #expect(innerLine.hasPrefix("  "))
        #expect(lines[0].hasPrefix(" ") == false)
    }

    // MARK: - Bounded output (privacy + buffer-eviction defences)

    @Test func describeTruncatesLongUserInfoValues() {
        // Stands in for `CKError.serverRecordChanged`'s ServerRecord/ClientRecord values, whose
        // `String(describing:)` prints the record's whole `values` dictionary — which for `Article`
        // includes `content` (full HTML) and `plainText`.
        let body = String(repeating: "A", count: 50_000)
        let error = NSError(
            domain: "CKErrorDomain",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "Server record changed",
                "ServerRecord": "<CKRecord: Article-42; values={content=\(body)}>",
            ]
        )

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("[ServerRecord]"))
        // The head survives, so the record type and ID are still diagnosable…
        #expect(joined.contains("CKRecord: Article-42"))
        // …but the body cannot leak.
        #expect(joined.contains(String(repeating: "A", count: 1000)) == false)
        #expect(joined.contains("more characters elided"))
        // Bounded by the cap plus the short elision suffix, not by the 50 KB input.
        #expect(joined.count < CloudKitSyncMonitor.maxUserInfoValueLength * 4)
    }

    @Test func truncateLeavesShortValuesUntouched() {
        #expect(CloudKitSyncMonitor.truncate("short") == "short")
        let exact = String(repeating: "x", count: CloudKitSyncMonitor.maxUserInfoValueLength)
        #expect(CloudKitSyncMonitor.truncate(exact) == exact)
    }

    @Test func describeCapsPartialErrorsAndReportsTheRemainder() {
        var partials: [String: NSError] = [:]
        for index in 0..<75 {
            // Zero-padded so the sorted order is stable and the cap is deterministic.
            partials[String(format: "Article-%03d", index)] = NSError(
                domain: "CKErrorDomain", code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Server record changed"]
            )
        }
        let error = NSError(
            domain: "CKErrorDomain", code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                "CKPartialErrors": partials,
            ]
        )

        let lines = CloudKitSyncMonitor.describe(error)
        let expanded = lines.filter { $0.contains("PartialError for") }
        #expect(expanded.count == CloudKitSyncMonitor.maxExpandedPartialErrors)
        #expect(lines.contains { $0.contains("… and 55 more partial error(s)") })
        // The first 20 by sorted key, so the tail is the elided part.
        #expect(expanded.first?.contains("Article-000") == true)
        #expect(lines.contains { $0.contains("Article-074") } == false)
    }

    @Test func describeRecursesPerElementEvenWhenSomePartialValuesAreNotErrors() {
        // A single non-`NSError` value used to defeat the blanket `as? [AnyHashable: NSError]` cast
        // and collapse the *whole* tree onto the non-recursing fallback.
        let sub = NSError(domain: "CKErrorDomain", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Server record changed"])
        let error = NSError(
            domain: "CKErrorDomain", code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                "CKPartialErrors": ["A-real": sub, "B-bogus": "not an error"] as [String: Any],
            ]
        )

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("PartialError for A-real:"))
        #expect(joined.contains("CKErrorDomain Code=14"))
        #expect(joined.contains("PartialDict[B-bogus]: not an error"))
    }

    @Test func phaseNameCoversEveryEventType() {
        #expect(CloudKitSyncMonitor.phaseName(.setup) == "setup")
        #expect(CloudKitSyncMonitor.phaseName(.import) == "import")
        #expect(CloudKitSyncMonitor.phaseName(.export) == "export")
    }

    @Test func startIsIdempotentAndLogsOnce() {
        let log = SyncLog(capacity: 50)
        let monitor = CloudKitSyncMonitor(log: log)
        monitor.start()
        monitor.start()

        let starts = log.snapshot().filter { $0.message.contains("Sync monitor started") }
        #expect(starts.count == 1)
    }

    /// Without this line an exported log carries no container, no CloudKit environment, and no app
    /// version — and environment mismatch is one of the two most likely causes of a sync report.
    @Test func startStampsTheContainerEnvironmentAndVersion() {
        let log = SyncLog(capacity: 50)
        CloudKitSyncMonitor(log: log).start()

        let joined = log.snapshot().map(\.message).joined(separator: "\n")
        #expect(joined.contains(SyncDiagnostics.containerIdentifier))
        #expect(joined.contains(SyncDiagnostics.environment))
        #expect(joined.contains(AppInfo.versionDisplay))
    }

    @Test func accountStatusIsLoggedAtMostOnce() async {
        let log = SyncLog(capacity: 50)
        let monitor = CloudKitSyncMonitor(log: log)
        await monitor.logAccountStatusOnce(probe: { "Available" })
        await monitor.logAccountStatusOnce(probe: { "Available" })

        let lines = log.snapshot().filter { $0.message.contains("iCloud account status") }
        #expect(lines.count == 1)
        #expect(lines.first?.message.contains("Available") == true)
    }
}
