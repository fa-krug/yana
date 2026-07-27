import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct SyncDiagnosticsTests {

    @Test func describesEveryAccountStatus() {
        #expect(SyncDiagnostics.describe(.available) == "Available")
        #expect(SyncDiagnostics.describe(.noAccount) == "No iCloud account")
        #expect(SyncDiagnostics.describe(.restricted) == "Restricted")
        #expect(SyncDiagnostics.describe(.couldNotDetermine) == "Could not determine")
    }

    @Test func environmentNameMapsDebugToDevelopmentAndReleaseToProduction() {
        #expect(SyncDiagnostics.environmentName(isDebugBuild: true) == "Development")
        #expect(SyncDiagnostics.environmentName(isDebugBuild: false) == "Production")
    }

    @Test func environmentReflectsTheBuildConfiguration() {
        #if DEBUG
        #expect(SyncDiagnostics.environment == "Development")
        #else
        #expect(SyncDiagnostics.environment == "Production")
        #endif
    }

    @Test func appInfoBuildsAVersionDisplayString() {
        #expect(AppInfo.versionDisplay == "\(AppInfo.version) (\(AppInfo.build))")
        #expect(AppInfo.versionDisplay.isEmpty == false)
    }

    @Test func makeCountsRowsFromTheContext() async throws {
        let container = try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(Tag(name: "Diagnostics probe"))
        try context.save()

        let diagnostics = await SyncDiagnostics.make(context: context)
        #expect(diagnostics.tagCount == 1)
        #expect(diagnostics.feedCount == 0)
        #expect(diagnostics.containerIdentifier == "iCloud.de.fa-krug.Yana")
        #expect(diagnostics.appVersion == AppInfo.versionDisplay)
    }
}
