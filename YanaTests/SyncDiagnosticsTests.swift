import CloudKit
import Foundation
import SwiftData
import SwiftUI
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

    private func sample(lastErrorSummary: String? = nil, systemLogEntryCount: Int? = nil) -> SyncDiagnostics {
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
            lastErrorSummary: lastErrorSummary,
            systemLogEntryCount: systemLogEntryCount
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
        #expect(header.contains("System Log: Unavailable"))
        // 1_000_000s after the epoch is 12 Jan 1970 in every plausible local time zone; matched
        // loosely so the assertion cannot flake on the runner's zone.
        #expect(header.contains("Last Import: 1970-01-1"))
        #expect(header.contains("Last Export: —"))
    }

    // MARK: - Library summary

    /// Review finding 6: `exportHeader()`'s "System Log" line was fixed to singularize, but the
    /// "Library" line immediately above it — same function, same dump — still hand-built the four
    /// nouns without singularizing any of them. Each noun must independently read "1 X", not "1 Xs".
    @Test func librarySummarySingularizesEachNounIndependently() {
        #expect(SyncDiagnostics.librarySummary(feedCount: 1, tagCount: 1, articleCount: 1, storedImageCount: 1)
            == "1 feed · 1 tag · 1 article · 1 image")
    }

    @Test func librarySummaryPluralizesCountsOtherThanOne() {
        #expect(SyncDiagnostics.librarySummary(feedCount: 0, tagCount: 2, articleCount: 210, storedImageCount: 97)
            == "0 feeds · 2 tags · 210 articles · 97 images")
    }

    @Test func exportHeaderSingularizesTheLibraryLineWhenEveryCountIsOne() {
        let diagnostics = sample()
        let oneOfEach = SyncDiagnostics(
            accountStatus: diagnostics.accountStatus,
            containerIdentifier: diagnostics.containerIdentifier,
            environment: diagnostics.environment,
            appVersion: diagnostics.appVersion,
            systemVersion: diagnostics.systemVersion,
            idiom: diagnostics.idiom,
            feedCount: 1,
            tagCount: 1,
            articleCount: 1,
            storedImageCount: 1,
            lastImportSucceededAt: diagnostics.lastImportSucceededAt,
            lastExportSucceededAt: diagnostics.lastExportSucceededAt,
            lastErrorSummary: diagnostics.lastErrorSummary,
            systemLogEntryCount: diagnostics.systemLogEntryCount
        )
        #expect(oneOfEach.exportHeader().contains("Library: 1 feed · 1 tag · 1 article · 1 image"))
    }

    // MARK: - System log summary

    /// The whole point of this line: "0 entries" (log opened, nothing persisted) must read
    /// differently from "Unavailable" (log could not be read at all) — a reader must never confuse
    /// the two.
    @Test func systemLogSummaryDistinguishesUnavailableFromAnHonestZero() {
        #expect(SyncDiagnostics.systemLogSummary(nil) == "Unavailable")
        #expect(SyncDiagnostics.systemLogSummary(0) == "0 entries")
        #expect(SyncDiagnostics.systemLogSummary(42) == "42 entries")
    }

    /// The boundary the earlier version of this function got wrong: `count == 1` must read "1
    /// entry", singular — not "1 entries". `exportHeader()` is developer-facing dump text and
    /// deliberately unlocalized, but that is not license for broken English grammar.
    @Test func systemLogSummarySingularizesACountOfOne() {
        #expect(SyncDiagnostics.systemLogSummary(1) == "1 entry")
    }

    /// Only the nil→"Unavailable" branch is checked via direct `Text` equality here: it is a plain
    /// `Text(verbatim:)` with no `LocalizedStringKey`/plural resolution involved, so structural
    /// equality is dependable. The count-bearing branch is **not** asserted this way — see
    /// `PluralAgreementTests.diagnosticsSystemLogRowCountAgrees()` for why and for the real coverage
    /// of that shape.
    @Test func systemLogTextIsVerbatimUnavailableWhenCountIsNil() {
        #expect(SyncDiagnostics.systemLogText(nil) == Text(verbatim: "Unavailable"))
    }

    @Test func exportHeaderReportsTheSystemLogCountWhenAvailable() {
        let header = sample(systemLogEntryCount: 7).exportHeader()
        #expect(header.contains("System Log: 7 entries"))
        #expect(header.contains("System Log: Unavailable") == false)
    }

    @Test func exportHeaderReportsUnavailableWhenTheSystemLogCountIsNil() {
        #expect(sample(systemLogEntryCount: nil).exportHeader().contains("System Log: Unavailable"))
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
