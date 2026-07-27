import CloudKit
import Foundation

/// Seam for testing: the production impl wraps `CKDatabase`; tests pass a fake.
protocol LegacyCloudKitDatabase: Sendable {
    func deleteRecordZone(name: String) async throws
    /// Deletes a record in the default zone by name.
    /// Implementations MUST swallow "not found" outcomes (CKError.unknownItem / zoneNotFound) so
    /// that devices which never used the old sync still mark cleanup as done.
    func deleteRecord(name: String) async throws
}

/// Production adapter over the user's private CloudKit database.
///
/// Not-found-as-success note: `deleteRecordZone` for a missing zone is already a server-side no-op,
/// but `deleteRecord` for a missing record throws `CKError.unknownItem`. Devices that never ran the
/// old sync have no `config` record, and we must NOT retry forever. The swallowing happens here, at
/// the protocol boundary, so `runIfNeeded` stays clean and the fake never needs to simulate it.
struct CloudKitLegacyDatabase: LegacyCloudKitDatabase {
    let database: CKDatabase
    init(containerID: String = "iCloud.de.fa-krug.Yana") {
        database = CKContainer(identifier: containerID).privateCloudDatabase
    }

    func deleteRecordZone(name: String) async throws {
        _ = try await database.deleteRecordZone(withID: CKRecordZone.ID(zoneName: name))
    }

    func deleteRecord(name: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: name))
        } catch {
            if Self.isNotFound(error) { return }
            throw error
        }
    }

    /// Returns true for errors that mean "the record/zone was never there" — these are treated as
    /// success so devices that never used the old sync can still mark the cleanup done.
    ///
    /// Extracted as a pure, testable function so the not-found logic can be verified directly
    /// without constructing a full CloudKit round-trip.
    static func isNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .unknownItem, .zoneNotFound:
            return true
        case .partialFailure:
            guard let partials = ckError.partialErrorsByItemID else { return false }
            return partials.values.allSatisfy { partialError in
                guard let partial = partialError as? CKError else { return false }
                return partial.code == .unknownItem || partial.code == .zoneNotFound
            }
        default:
            return false
        }
    }
}

/// Deletes the retired hand-built CloudKit artifacts from the user's private database:
///
/// - `Articles` record zone (CKSyncEngine zone)
/// - `SchemaBootstrap` zone (throwaway schema-push zone)
/// - `config` record (ConfigDocument) in the default zone
///
/// Best-effort and retried on later launches until it succeeds; never blocks the app.
/// A device that never used the old sync has no zones/records — the prod adapter treats
/// "not found" as success so those devices also mark the flag.
@MainActor
enum LegacyCloudKitCleanup {
    static func runIfNeeded(
        settings: AppSettings = AppSettings(),
        database: any LegacyCloudKitDatabase = CloudKitLegacyDatabase()
    ) async {
        guard !settings.hasCleanedLegacyCloudKit else { return }
        do {
            try await database.deleteRecordZone(name: "Articles")
            try await database.deleteRecordZone(name: "SchemaBootstrap")
            try await database.deleteRecord(name: "config")
            settings.hasCleanedLegacyCloudKit = true
            SyncLog.shared.info("Legacy CloudKit cleanup succeeded", category: "Cleanup")
        } catch {
            // Leave the flag unset so the next launch retries.
            // Network / auth errors land here; not-found is swallowed by the prod adapter.
            SyncLog.shared.notice("Legacy CloudKit cleanup deferred: \(error.localizedDescription)", category: "Cleanup")
        }
    }
}
