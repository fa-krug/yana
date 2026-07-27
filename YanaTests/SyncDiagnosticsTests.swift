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

    // MARK: - Export header

    private func sample(lastErrorSummary: String? = nil) -> SyncDiagnostics {
        SyncDiagnostics(
            accountStatus: "Available",
            containerIdentifier: SyncDiagnostics.containerIdentifier,
            environment: "Development",
            appVersion: "1.2.3 (45)",
            systemVersion: "iOS 26.0",
            idiom: "iPhone",
            feedCount: 4,
            tagCount: 3,
            articleCount: 210,
            storedImageCount: 97,
            lastImportSucceededAt: Date(timeIntervalSince1970: 1_000_000),
            lastExportSucceededAt: nil,
            lastErrorSummary: lastErrorSummary
        )
    }

    /// The header is what makes an exported log self-describing — without it a pasted log carries no
    /// account status, container, environment, version, OS, or row counts, and those are the two most
    /// likely causes of the failure being reported.
    @Test func exportHeaderCarriesEveryHeaderFact() {
        let header = sample().exportHeader()
        #expect(header.contains("iCloud Account: Available"))
        #expect(header.contains("Container: iCloud.de.fa-krug.Yana"))
        #expect(header.contains("Environment: Development"))
        #expect(header.contains("App: 1.2.3 (45)"))
        #expect(header.contains("System: iOS 26.0 · iPhone"))
        #expect(header.contains("Library: 4 feeds · 3 tags · 210 articles · 97 images"))
        // 1_000_000s after the epoch is 12 Jan 1970 in every plausible local time zone; matched
        // loosely so the assertion cannot flake on the runner's zone.
        #expect(header.contains("Last Import: 1970-01-1"))
        #expect(header.contains("Last Export: —"))
    }

    @Test func exportHeaderOmitsTheErrorLineWhenThereIsNoError() {
        #expect(sample().exportHeader().contains("Last Error") == false)
        #expect(sample(lastErrorSummary: "export: CKErrorDomain 2 — Partial failure")
            .exportHeader()
            .contains("Last Error (this launch): export: CKErrorDomain 2 — Partial failure"))
    }

    @Test func exportPayloadPrependsTheHeaderToTheEntryLines() {
        let entry = SyncLog.Entry(
            sequence: 1, date: Date(timeIntervalSince1970: 0), level: .error,
            category: "CloudKit", message: "export FAILED", source: .app
        )
        let payload = SyncLogView.exportPayload(entries: [entry], header: sample().exportHeader())
        #expect(payload.hasPrefix("=== Yana sync diagnostics ==="))
        #expect(payload.contains("export FAILED"))

        // No header available yet (the screen was opened and copied before the first snapshot).
        #expect(SyncLogView.exportPayload(entries: [entry], header: nil).contains("export FAILED"))
        #expect(SyncLogView.exportPayload(entries: [], header: sample().exportHeader())
            == sample().exportHeader())
    }

    // MARK: - Account probe guard

    /// `CKContainer(identifier:)` traps in an unsigned Mac Catalyst build, and the trap comes from the
    /// initializer so no `catch` can contain it — automation runs must never reach it.
    @Test func theAccountProbeIsSuppressedForAutomationRuns() {
        for argument in SyncDiagnostics.automationLaunchArguments {
            #expect(SyncDiagnostics.isAccountProbeSuppressed(arguments: ["Yana", argument]))
        }
        #expect(SyncDiagnostics.isAccountProbeSuppressed(arguments: ["Yana"]) == false)
    }

    @Test func aSuppressedProbeReportsNotCheckedRatherThanNoAccount() async {
        // Guard the semantics, not the plumbing: "Not checked" must never read as an account verdict.
        #expect(SyncDiagnostics.accountStatusNotChecked == "Not checked")
        #expect(SyncDiagnostics.accountStatusNotChecked != SyncDiagnostics.describe(.noAccount))
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
