#if DEBUG
import CloudKit
import CryptoKit
import Foundation

/// Pushes the app's CloudKit **schema** (record types and their fields) to the Development
/// environment, so a field added in code exists in the cloud without hand-editing the CloudKit
/// Console. DEBUG-only: schema changes belong to development, and Development → Production
/// promotion stays a deliberate manual step in the Console (Apple exposes no API for it).
///
/// Why this exists instead of `NSPersistentCloudKitContainer.initializeCloudKitSchema()`: that call
/// derives a schema from a Core Data managed object model, and Yana has none — the SwiftData store
/// is deliberately local-only (`cloudKitDatabase: .none`) and every `CKRecord` type here is
/// hand-authored for `CKSyncEngine`. So the equivalent is done the way CloudKit actually creates
/// schema: write one record per type with **every field populated**, then throw the records away.
/// The schema survives the deletion.
///
/// The problem it prevents: CloudKit infers a field from the first record that carries a value for
/// it, so a field that happens to be nil on every record the app writes is never created in the
/// cloud at all, and then silently never syncs. `SyncedArticle.iconURL` is optional and is exactly
/// this trap. The samples set every field non-nil.
///
/// Records are written into a throwaway `SchemaBootstrap` zone that is deleted afterwards, never
/// into the live `Articles` zone or over the live `config` document. Schema in CloudKit is
/// container-wide rather than per-zone, so a sample written in a scratch zone still defines the
/// type — and no fake article can ever reach the user's real devices, which only track `Articles`.
@MainActor
final class CloudKitSchemaBootstrap {
    /// Scratch zone the samples are written to and deleted with.
    static let zoneName = "SchemaBootstrap"
    /// Force a push on this launch, bypassing both the sync opt-in and the fingerprint check.
    ///
    /// Exists so the schema can be pushed *without* switching iCloud sync on, which would also start
    /// `ConfigSyncService`/`ArticleSyncService` reconciling the real library. A schema push touches
    /// nothing but the scratch zone, so this keeps that side effect out of a developer's account.
    static let forceLaunchArgument = "-PUSH_CLOUDKIT_SCHEMA"
    private static let fingerprintKey = "cloudKit.schemaFingerprint"
    /// Bump to force a re-push even when the field set is unchanged (e.g. after a field's *type*
    /// changes, which the field-name fingerprint alone cannot see).
    private static let schemaVersion = "1"

    /// Built on demand, never at init. Constructing a `CKContainer` costs real time at launch and
    /// *traps* in an unsigned Catalyst dev build, so the early-out paths in `pushIfNeeded()` must be
    /// reachable without one.
    private let makeContainer: () -> CKContainer
    private let defaults: UserDefaults
    private let settings: AppSettings
    /// `NSLog`, not `Logger`, on purpose: os_log output does not reliably surface from a locally
    /// built Mac Catalyst app, which is the one place a developer can run this against a real
    /// iCloud account. `DebugSeed`/`ScreenshotSeed` use NSLog for the same reason.
    private func report(_ message: String) { NSLog("CloudKitSchemaBootstrap: \(message)") }

    init(makeContainer: @escaping () -> CKContainer = { CKContainer(identifier: "iCloud.de.fa-krug.Yana") },
         defaults: UserDefaults = .standard,
         settings: AppSettings = AppSettings()) {
        self.makeContainer = makeContainer
        self.defaults = defaults
        self.settings = settings
    }

    // MARK: Entry points

    /// Push the schema only when the field set changed since the last successful push. Cheap no-op
    /// on every launch after that, so it is safe to call unconditionally at startup.
    ///
    /// Gated on `iCloudSyncEnabled`: the toggle is the user's opt-in to this app touching their
    /// CloudKit container at all, and a schema push is a write like any other.
    func pushIfNeeded() async {
        let forced = ProcessInfo.processInfo.arguments.contains(Self.forceLaunchArgument)
        guard forced || settings.iCloudSyncEnabled else { return }
        let current = Self.fingerprint
        guard forced || defaults.string(forKey: Self.fingerprintKey) != current else { return }
        do {
            try await push()
            // Record the fingerprint only on success, so a failed push retries next launch.
            defaults.set(current, forKey: Self.fingerprintKey)
            report("pushed schema for record types SyncedArticle, SyncedImage, ConfigDocument "
                   + "(fingerprint \(current))")
        } catch {
            report("push FAILED, will retry next launch: \(error)")
        }
    }

    /// A sample record CloudKit refused. Carries the record names so the log says which type failed.
    struct SchemaPushError: Error, CustomStringConvertible {
        let failures: [(recordName: String, error: Error)]
        var description: String {
            "CloudKit rejected schema samples: "
                + failures.map { "\($0.recordName): \($0.error)" }.joined(separator: "; ")
        }
    }

    /// Write one fully-populated sample of every record type, then delete the scratch zone.
    func push() async throws {
        let database = makeContainer().privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName)
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        do {
            let result = try await database.modifyRecords(
                saving: try Self.sampleRecords(in: zoneID), deleting: [])
            // `modifyRecords` reports per-record outcomes in its return value instead of throwing,
            // so a rejected sample (e.g. a field whose type conflicts with the existing schema) would
            // otherwise look like a clean success — `pushIfNeeded` would store the fingerprint and
            // never retry the very push that failed. Surface those failures as a thrown error.
            let failures = result.saveResults.compactMap { id, outcome -> (String, Error)? in
                if case .failure(let error) = outcome { return (id.recordName, error) }
                return nil
            }
            guard failures.isEmpty else {
                throw SchemaPushError(failures: failures.map { (recordName: $0.0, error: $0.1) })
            }
            // Report the *server's* echo of each saved record, not what we sent: these are the fields
            // CloudKit actually stored, which is the only token-free confirmation that the schema now
            // has them (reading the schema back needs a CloudKit management token).
            for record in result.saveResults.values
                .compactMap({ try? $0.get() })
                .sorted(by: { $0.recordType < $1.recordType }) {
                let keys = record.allKeys().sorted()
                report("CloudKit stored \(record.recordType) with \(keys.count) fields: "
                       + keys.joined(separator: ", "))
            }
        } catch {
            // Don't leave samples behind on a failed push.
            try? await database.deleteRecordZone(withID: zoneID)
            throw error
        }
        // The samples have served their purpose: the schema they defined is container-wide and
        // survives their deletion. A cleanup failure is logged rather than thrown — the schema push
        // itself succeeded, and failing here would re-push needlessly on every launch.
        do {
            try await database.deleteRecordZone(withID: zoneID)
        } catch {
            report("samples pushed but scratch zone cleanup failed: \(error)")
        }
    }

    // MARK: Samples

    /// One sample record per type, every field non-nil. Article records go through
    /// `CloudKitArticleZoneStore.ckRecord(from:recordID:)` — the same serializer the real push
    /// uses — so adding a field there automatically adds it here.
    static func sampleRecords(in zoneID: CKRecordZone.ID) throws -> [CKRecord] {
        let article = CloudKitArticleZoneStore.ckRecord(
            from: sampleArticle,
            recordID: CKRecord.ID(recordName: "schema-sample-article", zoneID: zoneID))

        // `SyncedImage` is two fields; built inline because the real serializer also tracks temp
        // files for the live send path. Keep in sync with `CloudKitArticleZoneStore.ckRecord(from:)`.
        let image = CKRecord(recordType: CloudKitArticleZoneStore.imageRecordType,
                             recordID: CKRecord.ID(recordName: "schema-sample-image", zoneID: zoneID))
        image["ext"] = "jpg" as CKRecordValue
        image["blob"] = CKAsset(fileURL: try sampleAssetURL())

        // Deliberately NOT the live `config` record name — that would overwrite the user's real
        // configuration document. Schema is container-wide, so a sample under any name defines it.
        let config = CKRecord(recordType: CloudKitConfigStore.recordType,
                              recordID: CKRecord.ID(recordName: "schema-sample-config", zoneID: zoneID))
        config[CloudKitConfigStore.opmlKey] = "<opml version=\"2.0\"></opml>" as CKRecordValue
        config[CloudKitConfigStore.settingsDataKey] = Data("{}".utf8) as CKRecordValue

        return [article, image, config]
    }

    /// Every field non-nil, so CloudKit creates a column for each one — including `iconURL`, which
    /// is optional in the model and is the field most likely to be missing from a schema inferred
    /// only from real traffic.
    static let sampleArticle = SyncedArticleRecord(
        uid: "schema-sample-article",
        feedIdentifier: "https://schema.sample/feed", aggregatorType: "feedContent",
        articleIdentifier: "https://schema.sample/post/1",
        title: "Schema sample", url: "https://schema.sample/post/1",
        author: "Schema", summary: "Schema sample summary", plainText: "Schema sample body",
        leadImageRef: "yana-img://schemasample", iconURL: "https://schema.sample/icon.png",
        date: Date(timeIntervalSince1970: 0), createdAt: Date(timeIntervalSince1970: 0),
        blockData: Data("[]".utf8), isStarred: true,
        tagNames: ["Schema"], imageHashes: ["schemasample"])

    private static let sampleImage = SyncedImageRecord(
        hash: "schemasample", ext: "jpg", data: Data([0xFF, 0xD8, 0xFF, 0xD9]))

    /// A `CKAsset` needs a file on disk; a few bytes are enough to define the field's type.
    private static func sampleAssetURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-sample-image.jpg")
        try sampleImage.data.write(to: url)
        return url
    }

    // MARK: Fingerprint

    /// Identifies the current schema shape by the field names of the sample records. Derived from
    /// the model types via `Mirror`, so adding a field to `SyncedArticleRecord` changes the
    /// fingerprint and the next DEBUG launch re-pushes on its own — no constant to remember to bump.
    static var fingerprint: String {
        let article = Mirror(reflecting: sampleArticle).children.compactMap(\.label)
        let image = Mirror(reflecting: sampleImage).children.compactMap(\.label)
        let config = [CloudKitConfigStore.opmlKey, CloudKitConfigStore.settingsDataKey]
        let seed = ([schemaVersion] + article.sorted() + image.sorted() + config.sorted())
            .joined(separator: ",")
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
