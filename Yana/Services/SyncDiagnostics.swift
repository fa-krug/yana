import CloudKit
import Foundation
import SwiftData
import UIKit

/// A point-in-time snapshot of everything worth knowing about this device's sync setup, shown pinned
/// above the diagnostics log.
///
/// The two most common causes of "sync doesn't work" are an account problem and a CloudKit
/// environment mismatch (a Debug build talks to Development, TestFlight/App Store talk to
/// Production, and the schema must be deployed to Production separately). Both are visible here
/// without reading a single log line.
struct SyncDiagnostics: Sendable {
    var accountStatus: String
    var containerIdentifier: String
    var environment: String
    var appVersion: String
    var systemVersion: String
    var idiom: String
    var feedCount: Int
    var tagCount: Int
    var articleCount: Int
    var storedImageCount: Int
    var lastImportSucceededAt: Date?
    var lastExportSucceededAt: Date?
    var lastErrorSummary: String?

    /// The private-database container SwiftData mirrors into.
    static let containerIdentifier = "iCloud.de.fa-krug.Yana"

    /// Which CloudKit environment this build talks to. Derived from the build configuration: the
    /// `aps-environment` entitlement lives in the code signature and is not reliably readable at
    /// runtime, and every shipping path agrees with the build configuration anyway.
    static var environment: String {
        #if DEBUG
        "Development"
        #else
        "Production"
        #endif
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "Available"
        case .noAccount: "No iCloud account"
        case .restricted: "Restricted"
        case .couldNotDetermine: "Could not determine"
        case .temporarilyUnavailable: "Temporarily unavailable"
        @unknown default: "Unknown"
        }
    }

    @MainActor
    static func make(
        context: ModelContext,
        monitor: CloudKitSyncMonitor = .shared
    ) async -> SyncDiagnostics {
        SyncDiagnostics(
            accountStatus: await accountStatusDescription(),
            containerIdentifier: containerIdentifier,
            environment: environment,
            appVersion: AppInfo.versionDisplay,
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            idiom: idiomName,
            feedCount: count(FetchDescriptor<Feed>(), in: context),
            tagCount: count(FetchDescriptor<Tag>(), in: context),
            articleCount: count(FetchDescriptor<Article>(), in: context),
            storedImageCount: count(FetchDescriptor<StoredImage>(), in: context),
            lastImportSucceededAt: monitor.lastImportSucceededAt(),
            lastExportSucceededAt: monitor.lastExportSucceededAt(),
            lastErrorSummary: monitor.lastErrorSummary()
        )
    }

    private static func accountStatusDescription() async -> String {
        do {
            let status = try await CKContainer(identifier: containerIdentifier).accountStatus()
            return describe(status)
        } catch {
            return "Unavailable: \(error.localizedDescription)"
        }
    }

    private static func count<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in context: ModelContext
    ) -> Int {
        (try? context.fetchCount(descriptor)) ?? -1
    }

    private static var idiomName: String {
        #if targetEnvironment(macCatalyst)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}
