import CloudKit
import Foundation
import SwiftData
import SwiftUI
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
    /// Real entries `SystemLogReader.fetch` read from the unified log — `nil` if that read failed
    /// outright (log unavailable), distinct from a legitimate zero (log opened, nothing persisted).
    var systemLogEntryCount: Int?

    /// The private-database container SwiftData mirrors into.
    static let containerIdentifier = "iCloud.de.fa-krug.Yana"

    /// Which CloudKit environment this build talks to. Derived from the build configuration: the
    /// `aps-environment` entitlement lives in the code signature and is not reliably readable at
    /// runtime, and every shipping path agrees with the build configuration anyway.
    static var environment: String {
        #if DEBUG
        environmentName(isDebugBuild: true)
        #else
        environmentName(isDebugBuild: false)
        #endif
    }

    /// The CloudKit environment name for a build. Pure, so the mapping is testable independently
    /// of the build configuration this target happens to be compiled with.
    static func environmentName(isDebugBuild: Bool) -> String {
        isDebugBuild ? "Development" : "Production"
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
        monitor: CloudKitSyncMonitor = .shared,
        systemLogEntryCount: Int? = nil
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
            lastErrorSummary: monitor.lastErrorSummary(),
            systemLogEntryCount: systemLogEntryCount
        )
    }

    /// Reported instead of a real status when the probe is suppressed. Deliberately honest — "Not
    /// checked" must never be mistaken for "no account".
    static let accountStatusNotChecked = "Not checked"

    /// Whether the `CKContainer` account probe must be skipped entirely for this process.
    ///
    /// **Trap hazard — this guard is load-bearing.** `CKContainer(identifier:)` *traps*
    /// (EXC_BREAKPOINT / SIGTRAP, exit 133) in an **unsigned** Mac Catalyst build. Because the trap is
    /// raised by the *initializer*, a `do`/`catch` around `accountStatus()` cannot contain it — the
    /// process dies. Earlier work deliberately moved `CKContainer` off the launch path for exactly
    /// this reason; the diagnostics screen put a construction behind a user tap, so the automation
    /// paths this project actually drives from an unsigned build (UI tests and the screenshot lanes)
    /// have to be excluded by name. Do **not** replace this with a runtime code-signing check: there
    /// is no reliable one.
    static var isAccountProbeSuppressed: Bool {
        isAccountProbeSuppressed(arguments: ProcessInfo.processInfo.arguments)
    }

    /// The launch arguments that mark an automation run. Spelled out rather than read off
    /// `MacScreenshotWindow.launchArgument`, which is compiled out of release builds; this guard is
    /// not (a release UI-test run must be protected too).
    static let automationLaunchArguments = [
        "-UITEST_MAC_SCREENSHOTS",
        "-UITEST_SCREENSHOTS",
        "-UITEST_RESET_LIBRARY",
        "-UITEST_SKIP_ONBOARDING",
    ]

    /// Pure form, so the rule is testable without launching under those arguments.
    static func isAccountProbeSuppressed(arguments: [String]) -> Bool {
        arguments.contains { automationLaunchArguments.contains($0) }
    }

    /// The system-log line's rendered value for `exportHeader()`: a count when
    /// `SystemLogReader.fetch` succeeded (0 is a legitimate, honest answer — "the log was open and
    /// had nothing persisted"), or "Unavailable" when the read itself failed. Pure so the mapping is
    /// testable without a live `OSLogStore` fetch.
    ///
    /// Deliberately **not** localized — `exportHeader()` as a whole is documented as developer-facing
    /// dump text, matching every other dynamic value in it (`accountStatus`, `environment`, the
    /// `Library` counts). But "not localized" does not mean "grammatically wrong": `count == 1` must
    /// still read "1 entry", not "1 entries" — that bug is independent of localization, and English
    /// is the one language this string is ever shown in.
    static func systemLogSummary(_ count: Int?) -> String {
        guard let count else { return "Unavailable" }
        return count == 1 ? "1 entry" : "\(count) entries"
    }

    /// Hand-pluralizes each of the four `Library:` row nouns for `exportHeader()`, matching the
    /// precedent `systemLogSummary(_:)` already sets for this same deliberately-unlocalized dump
    /// text (see `exportHeader()`'s doc comment): not localized, but that is not license for broken
    /// English grammar — `count == 1` must read singular for each noun independently ("1 feed", not
    /// "1 feeds"), the same bug class `systemLogSummary(_:)` was fixed for.
    static func librarySummary(feedCount: Int, tagCount: Int, articleCount: Int, storedImageCount: Int) -> String {
        [
            pluralCount(feedCount, singular: "feed", plural: "feeds"),
            pluralCount(tagCount, singular: "tag", plural: "tags"),
            pluralCount(articleCount, singular: "article", plural: "articles"),
            pluralCount(storedImageCount, singular: "image", plural: "images"),
        ].joined(separator: " · ")
    }

    private static func pluralCount(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// Convenience over `systemLogEntryCount`, shared by `exportHeader()`.
    var systemLogSummary: String { Self.systemLogSummary(systemLogEntryCount) }

    /// SwiftUI-rendered form of the same value, for the pinned header row. Unlike
    /// `systemLogSummary()` above, this **is** shown directly to the user, so the count-bearing noun
    /// must route through the string catalog rather than being hand-built — the same treatment the
    /// `Library` row already gets, and Global Constraint 5's exact subject. Reuses the existing
    /// `"%lld entries"` catalog key (already carrying correct `en`/`de` `one`/`other` plural forms)
    /// by building the identical `Text("\(count) entries")` shape `SyncLogView`'s own section header
    /// uses, rather than adding a near-duplicate localized string. "Unavailable" is not a
    /// count-bearing noun, so it stays verbatim — consistent with every other status word on this
    /// screen (`accountStatus`'s "Unavailable: …", `describe(_:)`'s case strings).
    static func systemLogText(_ count: Int?) -> Text {
        guard let count else { return Text(verbatim: "Unavailable") }
        return Text("\(count) entries")
    }

    /// Convenience over `systemLogEntryCount`, used by the pinned header view.
    var systemLogText: Text { Self.systemLogText(systemLogEntryCount) }

    static func accountStatusDescription() async -> String {
        guard !isAccountProbeSuppressed else { return accountStatusNotChecked }
        do {
            // The construction on the next line is the trap site — see `isAccountProbeSuppressed`.
            let status = try await CKContainer(identifier: containerIdentifier).accountStatus()
            return describe(status)
        } catch {
            return "Unavailable: \(error.localizedDescription)"
        }
    }

    /// The block prepended to an exported log, so a log pasted into an issue is self-describing.
    ///
    /// Lives here rather than in the view because this is the type that owns the data. Deliberately
    /// **not** localized: an exported log is developer-facing and travels to a bug tracker, where a
    /// German header over English entry lines would only make it harder to read.
    func exportHeader() -> String {
        var lines = [
            "=== Yana sync diagnostics ===",
            "iCloud Account: \(accountStatus)",
            "Container: \(containerIdentifier)",
            "Environment: \(environment)",
            "App: \(appVersion)",
            "System: \(systemVersion) · \(idiom)",
            "Library: \(Self.librarySummary(feedCount: feedCount, tagCount: tagCount, articleCount: articleCount, storedImageCount: storedImageCount))",
            "System Log: \(systemLogSummary)",
            "Last Import: \(Self.stamp(lastImportSucceededAt))",
            "Last Export: \(Self.stamp(lastExportSucceededAt))",
        ]
        if let lastErrorSummary {
            lines.append("Last Error (this launch): \(lastErrorSummary)")
        }
        lines.append("=============================")
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return ISO8601DateFormatter.string(
            from: date,
            timeZone: .current,
            formatOptions: [.withInternetDateTime]
        )
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
