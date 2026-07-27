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
}
