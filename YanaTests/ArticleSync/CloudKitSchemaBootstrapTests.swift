#if DEBUG
import CloudKit
import Foundation
import Testing
@testable import Yana

@Suite("CloudKitSchemaBootstrap")
@MainActor
struct CloudKitSchemaBootstrapTests {
    /// The sample records, built the way `push()` builds them.
    private func samples() throws -> [CKRecord] {
        try CloudKitSchemaBootstrap.sampleRecords(
            in: CKRecordZone.ID(zoneName: CloudKitSchemaBootstrap.zoneName))
    }

    @Test("Every SyncedArticle field the real serializer writes is populated in the sample")
    func articleSampleHasEveryField() throws {
        let article = try #require(
            samples().first { $0.recordType == CloudKitArticleZoneStore.articleRecordType })
        // The whole point of the bootstrap: an optional left nil never gets a column in CloudKit,
        // so every field the serializer emits must carry a value here — `iconURL` especially.
        let expected = [
            "feedIdentifier", "aggregatorType", "articleIdentifier", "title", "url", "author",
            "summary", "plainText", "leadImageRef", "iconURL", "date", "createdAt", "blockData",
            "isStarred", "tagNames", "imageHashes"
        ]
        #expect(Set(article.allKeys()) == Set(expected))
        for key in expected {
            #expect(article[key] != nil, "\(key) must be non-nil or CloudKit won't create the field")
        }
    }

    @Test("The sample never writes over the live config document")
    func configSampleDoesNotClobberLiveRecord() throws {
        let config = try #require(
            samples().first { $0.recordType == CloudKitConfigStore.recordType })
        // Writing recordName "config" would destroy the user's real synced configuration.
        #expect(config.recordID.recordName != CloudKitConfigStore.recordName)
        #expect(config[CloudKitConfigStore.opmlKey] != nil)
        #expect(config[CloudKitConfigStore.settingsDataKey] != nil)
    }

    @Test("Samples stay out of the live Articles zone")
    func samplesUseTheScratchZone() throws {
        // A sample landing in `Articles` would sync down to real devices as a fake article.
        for record in try samples() {
            #expect(record.recordID.zoneID.zoneName == CloudKitSchemaBootstrap.zoneName)
            #expect(record.recordID.zoneID.zoneName != CloudKitArticleZoneStore.zoneName)
        }
    }

    @Test("All three record types are covered")
    func coversEveryRecordType() throws {
        #expect(Set(try samples().map(\.recordType)) == [
            CloudKitArticleZoneStore.articleRecordType,
            CloudKitArticleZoneStore.imageRecordType,
            CloudKitConfigStore.recordType
        ])
    }

    @Test("The image sample carries a real asset so the blob field gets created")
    func imageSampleHasAsset() throws {
        let image = try #require(
            samples().first { $0.recordType == CloudKitArticleZoneStore.imageRecordType })
        #expect(image["ext"] as? String == "jpg")
        let asset = try #require(image["blob"] as? CKAsset)
        let url = try #require(asset.fileURL)
        #expect((try? Data(contentsOf: url))?.isEmpty == false)
    }

    @Test("The fingerprint changes when the article field set changes")
    func fingerprintTracksFieldSet() {
        // Stable across calls...
        #expect(CloudKitSchemaBootstrap.fingerprint == CloudKitSchemaBootstrap.fingerprint)
        // ...and derived from the model's field names, so a new field re-triggers the push. Mirror
        // over the record struct is what makes that automatic.
        let fields = Mirror(reflecting: CloudKitSchemaBootstrap.sampleArticle)
            .children.compactMap(\.label)
        #expect(fields.contains("iconURL"))
        #expect(fields.count == 17)   // 16 CloudKit fields + `uid` (the record name)
    }

    @Test("pushIfNeeded is a no-op while iCloud sync is off")
    func skipsWhenSyncDisabled() async {
        let defaults = UserDefaults(suiteName: "schema-bootstrap-test-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.iCloudSyncEnabled = false
        // A container factory that fails the test if called: the opt-in gate must be checked before
        // any CloudKit object is built (constructing CKContainer traps in unsigned Catalyst builds).
        let bootstrap = CloudKitSchemaBootstrap(
            makeContainer: { Issue.record("must not touch CloudKit while sync is disabled")
                             return CKContainer(identifier: "iCloud.de.fa-krug.Yana") },
            defaults: defaults, settings: settings)
        await bootstrap.pushIfNeeded()
        #expect(defaults.string(forKey: "cloudKit.schemaFingerprint") == nil)
    }

    @Test("pushIfNeeded skips when the stored fingerprint already matches")
    func skipsWhenFingerprintMatches() async {
        let defaults = UserDefaults(suiteName: "schema-bootstrap-test-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.iCloudSyncEnabled = true
        defaults.set(CloudKitSchemaBootstrap.fingerprint, forKey: "cloudKit.schemaFingerprint")
        let bootstrap = CloudKitSchemaBootstrap(
            makeContainer: { Issue.record("must not re-push an unchanged schema")
                             return CKContainer(identifier: "iCloud.de.fa-krug.Yana") },
            defaults: defaults, settings: settings)
        await bootstrap.pushIfNeeded()
    }
}
#endif
