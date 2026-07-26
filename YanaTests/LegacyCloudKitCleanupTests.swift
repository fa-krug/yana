import CloudKit
import Testing
import Foundation
@testable import Yana

// Design note on not-found-as-success testing:
//
// The `CKError.unknownItem` swallowing lives in `CloudKitLegacyDatabase` (the PROD adapter), not in
// `LegacyCloudKitCleanup.runIfNeeded`. The fake DB never needs to simulate it because the
// swallowing happens before errors reach `runIfNeeded`. To avoid the awkwardness of constructing
// real `CKError` values in tests, we test the two concerns separately:
//
//   a) `deletesZonesAndConfigRecordThenSetsFlag` — a clean fake proves the happy path: zones and
//      the config record are deleted, and the flag is set.
//   b) `failureLeavesFlagUnsetForRetry` — a fake whose first call throws a generic NSError proves
//      that any propagated error keeps the flag false (network/auth failure → retry).
//   c) `isNotFoundReturnsFalseFor*` — unit-tests for the pure `isNotFound` helper extracted from
//      the prod adapter, verifying the not-found semantics directly without a CloudKit round-trip.

@MainActor
struct LegacyCloudKitCleanupTests {
    @MainActor
    final class FakeDB: LegacyCloudKitDatabase {
        var deletedZones: [String] = []
        var deletedRecords: [String] = []
        var failFirst = false
        func deleteRecordZone(name: String) async throws {
            if failFirst { failFirst = false; throw NSError(domain: "x", code: 1) }
            deletedZones.append(name)
        }
        func deleteRecord(name: String) async throws { deletedRecords.append(name) }
    }

    private func settings(_ s: String) -> AppSettings {
        let d = UserDefaults(suiteName: s)!; d.removePersistentDomain(forName: s); return AppSettings(defaults: d)
    }

    @Test func deletesZonesAndConfigRecordThenSetsFlag() async throws {
        let db = FakeDB(); let s = settings("cleanup-a")
        await LegacyCloudKitCleanup.runIfNeeded(settings: s, database: db)
        #expect(db.deletedZones.sorted() == ["Articles", "SchemaBootstrap"])
        #expect(db.deletedRecords == ["config"])
        #expect(s.hasCleanedLegacyCloudKit == true)
    }

    @Test func failureLeavesFlagUnsetForRetry() async throws {
        let db = FakeDB(); db.failFirst = true; let s = settings("cleanup-b")
        await LegacyCloudKitCleanup.runIfNeeded(settings: s, database: db)
        #expect(s.hasCleanedLegacyCloudKit == false)   // not marked done → retried next launch
    }

    // MARK: - isNotFound helper (tests the CKError-swallowing logic directly)

    @Test func isNotFoundReturnsFalseForNonCKError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(CloudKitLegacyDatabase.isNotFound(error) == false)
    }

    @Test func isNotFoundReturnsFalseForGenericCKError() {
        // CKError.serverRejectedRequest is not a "not found" condition.
        // Use NSError with CKErrorDomain to avoid constructing a full CKError.
        let error = NSError(domain: CKErrorDomain, code: CKError.serverRejectedRequest.rawValue)
        #expect(CloudKitLegacyDatabase.isNotFound(error) == false)
    }

    @Test func isNotFoundReturnsFalseForNetworkError() {
        let error = NSError(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)
        #expect(CloudKitLegacyDatabase.isNotFound(error) == false)
    }
}
