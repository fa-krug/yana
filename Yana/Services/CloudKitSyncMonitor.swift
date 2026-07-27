import CloudKit
import CoreData
import Foundation
import os

/// Observes SwiftData's CloudKit mirroring and records every setup/import/export event into
/// `SyncLog`, including the **full** error tree.
///
/// This is the piece that makes the diagnostics log worth reading: `NSPersistentCloudKitContainer`
/// reports failures through `eventChangedNotification`, and Apple's own `com.apple.coredata` logging
/// redacts the useful values to `<private>`. Re-logging the `NSError` tree ourselves with
/// `privacy: .public` is what turns "sync doesn't work" into a domain, a code, and a message.
///
/// **Ordering is load-bearing:** `start()` must run before the live `.automatic` `ModelContainer` is
/// created (see `AppContainer.shared`). Setup events fire during `ModelContainer.init`, and those are
/// exactly where a container-, entitlement-, or account-level failure surfaces — an observer
/// installed afterwards misses them.
final class CloudKitSyncMonitor: Sendable {
    static let shared = CloudKitSyncMonitor()

    /// `SyncLog` category for every line this type emits.
    static let category = "CloudKit"

    /// `CKPartialErrorsByItemIDKey`'s raw value, spelled out so the walker can read it out of a
    /// plain `userInfo` dictionary without importing the constant's optionality.
    static let partialErrorsKey = "CKPartialErrors"

    /// Hard cap on how many characters of a single `userInfo` value reach a log line.
    ///
    /// **This is a privacy control, not cosmetics — do not remove it.** `CKError.serverRecordChanged`
    /// (code 14) carries `ServerRecord` / `ClientRecord` / `AncestorRecord` values that are whole
    /// `CKRecord`s, and `String(describing: CKRecord)` prints the record's entire `values` dictionary.
    /// `Article` mirrors `title`, `url`, `content` (full HTML), `plainText`, `summary`, and `author` as
    /// plain `String` attributes, so an unbounded dump would put full article bodies into a log the
    /// user is invited to copy into a bug report — and, because every `SyncLog` entry is mirrored to
    /// `Logger` with `privacy: .public`, into the device's persisted unified log with no user action
    /// at all. For an app whose premise is that content never leaves the device, that is not
    /// shippable. 400 characters keeps the diagnostically useful head of every value (record type,
    /// record ID, error text) while making a body dump impossible.
    static let maxUserInfoValueLength = 400

    /// Hard cap on how many `CKPartialErrors` sub-errors are expanded.
    ///
    /// A CloudKit export batch carries up to ~400 records, so one `CKError.partialFailure` can
    /// describe hundreds of them. Expanding all of them would produce thousands of lines from a
    /// single event and — even now that the tree is one buffer entry — make the entry unreadable.
    /// The tail line reports how many were elided so the scale of the failure is never hidden.
    static let maxExpandedPartialErrors = 20

    private struct State {
        var isObserving = false
        var hasLoggedAccountStatus = false
        var lastImportSucceededAt: Date?
        var lastExportSucceededAt: Date?
        var lastErrorSummary: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log: SyncLog

    init(log: SyncLog = .shared) {
        self.log = log
    }

    // MARK: - Lifecycle

    /// Install the mirroring-event and account-change observers. Idempotent.
    func start() {
        let alreadyObserving = state.withLock { state -> Bool in
            if state.isObserving { return true }
            state.isObserving = true
            return false
        }
        guard !alreadyObserving else { return }

        log.info("Sync monitor started", category: Self.category)
        // Stamp the environment into the entry stream itself, not only into the (view-only)
        // diagnostics header: an exported log has to be self-describing, and container identifier +
        // CloudKit environment + app version are the three facts that most often name the bug.
        log.notice(
            "Container \(SyncDiagnostics.containerIdentifier) · environment \(SyncDiagnostics.environment) · app \(AppInfo.versionDisplay)",
            category: Self.category
        )
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            record(event)
        }

        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [self] _ in
            log.notice("iCloud account changed", category: Self.category)
        }
    }

    /// Record the iCloud account status in the entry stream, at most once per launch.
    ///
    /// Deliberately **not** called from `start()`, even though the status belongs with the other
    /// one-shot setup facts: `start()` runs on the synchronous launch path, and
    /// `CKContainer(identifier:)` *traps* in an unsigned Mac Catalyst build (see
    /// `SyncDiagnostics.isAccountProbeSuppressed`). A container construction there would kill the
    /// launched-by-path local dev build the project uses to sanity-check the launch path, and no
    /// `catch` could contain it. The status is only ever *read* through the diagnostics screen and its
    /// exported header, so logging it the first time that screen asks is still "once, asynchronously,
    /// as soon as it is determined" — just not at a moment that can take the process down.
    ///
    /// `probe` is injectable so the one-shot behaviour is testable without touching CloudKit.
    func logAccountStatusOnce(
        probe: @Sendable () async -> String = { await SyncDiagnostics.accountStatusDescription() }
    ) async {
        let alreadyLogged = state.withLock { state -> Bool in
            if state.hasLoggedAccountStatus { return true }
            state.hasLoggedAccountStatus = true
            return false
        }
        guard !alreadyLogged else { return }
        log.notice("iCloud account status: \(await probe())", category: Self.category)
    }

    // MARK: - Reads for the diagnostics header

    func lastImportSucceededAt() -> Date? { state.withLock { $0.lastImportSucceededAt } }
    func lastExportSucceededAt() -> Date? { state.withLock { $0.lastExportSucceededAt } }
    func lastErrorSummary() -> String? { state.withLock { $0.lastErrorSummary } }

    // MARK: - Event recording

    private func record(_ event: NSPersistentCloudKitContainer.Event) {
        let phase = Self.phaseName(event.type)

        if let error = event.error as NSError? {
            // ONE entry for the whole tree, not one per line. A `CKError.partialFailure` describes up
            // to a full export batch, so per-line entries evicted the entire 2000-entry buffer from a
            // single event — including the `setup` lines that carry the container/entitlement/account
            // evidence the load-bearing `start()`-before-`ModelContainer` ordering exists to capture.
            // The feature would have destroyed its own most important evidence.
            let tree = Self.describe(error)
            log.error(
                "\(phase) FAILED\n" + tree.joined(separator: "\n"),
                category: Self.category
            )
            let summary = "\(phase): \(error.domain) \(error.code) — \(error.localizedDescription)"
            state.withLock { $0.lastErrorSummary = summary }
            return
        }

        guard let endDate = event.endDate else {
            log.debug("\(phase) started", category: Self.category)
            return
        }

        log.info("\(phase) succeeded", category: Self.category)
        // Extract the (Sendable) event type before entering the lock: `OSAllocatedUnfairLock`'s
        // `withLock` closure is `@Sendable`, and `NSPersistentCloudKitContainer.Event` itself is not
        // `Sendable`, so capturing `event` directly here would be a strict-concurrency error.
        let eventType = event.type
        state.withLock { state in
            switch eventType {
            case .import: state.lastImportSucceededAt = endDate
            case .export: state.lastExportSucceededAt = endDate
            default: break
            }
        }
    }

    static func phaseName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "event(\(type.rawValue))"
        }
    }

    /// Flatten an `NSError` into log lines: the error itself, every `userInfo` key, up to
    /// `maxExpandedPartialErrors` `CKPartialErrors` sub-errors, and the underlying error —
    /// recursively, indented by depth. Every rendered value is truncated to
    /// `maxUserInfoValueLength`. Pure, so it can be unit-tested without CloudKit.
    static func describe(_ error: NSError, depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)\(error.domain) Code=\(error.code): \(truncate(error.localizedDescription))"]

        for key in error.userInfo.keys.sorted() {
            guard key != NSUnderlyingErrorKey, key != partialErrorsKey else { continue }
            let value = error.userInfo[key].map { truncate(String(describing: $0)) } ?? "nil"
            lines.append("\(indent)  [\(key)]: \(value)")
        }

        // One path, cast element-wise. A blanket `as? [AnyHashable: NSError]` is all-or-nothing, so a
        // single non-`NSError` value in the dictionary collapsed the *entire* tree onto the
        // non-recursing fallback — losing every sub-error's domain and code.
        if let partials = error.userInfo[partialErrorsKey] as? NSDictionary {
            let keys = partials.allKeys.sorted { String(describing: $0) < String(describing: $1) }
            for key in keys.prefix(maxExpandedPartialErrors) {
                let value = partials[key]
                if let sub = value as? NSError {
                    lines.append("\(indent)  PartialError for \(truncate(String(describing: key))):")
                    lines.append(contentsOf: describe(sub, depth: depth + 2))
                } else {
                    let rendered = value.map { truncate(String(describing: $0)) } ?? "nil"
                    lines.append("\(indent)  PartialDict[\(truncate(String(describing: key)))]: \(rendered)")
                }
            }
            if keys.count > maxExpandedPartialErrors {
                lines.append("\(indent)  … and \(keys.count - maxExpandedPartialErrors) more partial error(s)")
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("\(indent)  Underlying:")
            lines.append(contentsOf: describe(underlying, depth: depth + 1))
        }

        return lines
    }

    /// Bound a single rendered value. See `maxUserInfoValueLength` — this is the privacy control that
    /// keeps a `CKRecord` dump (and therefore full article bodies) out of the log.
    static func truncate(_ value: String) -> String {
        guard value.count > maxUserInfoValueLength else { return value }
        let head = value.prefix(maxUserInfoValueLength)
        return "\(head)… (\(value.count - maxUserInfoValueLength) more characters elided)"
    }
}
