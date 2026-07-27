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

    private struct State {
        var isObserving = false
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

    // MARK: - Reads for the diagnostics header

    func lastImportSucceededAt() -> Date? { state.withLock { $0.lastImportSucceededAt } }
    func lastExportSucceededAt() -> Date? { state.withLock { $0.lastExportSucceededAt } }
    func lastErrorSummary() -> String? { state.withLock { $0.lastErrorSummary } }

    // MARK: - Event recording

    private func record(_ event: NSPersistentCloudKitContainer.Event) {
        let phase = Self.phaseName(event.type)

        if let error = event.error as NSError? {
            log.error("\(phase) FAILED", category: Self.category)
            for line in Self.describe(error) {
                log.error(line, category: Self.category)
            }
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

    /// Flatten an `NSError` into log lines: the error itself, every `userInfo` key, every
    /// `CKPartialErrors` sub-error, and the underlying error — recursively, indented by depth.
    /// Pure, so it can be unit-tested without CloudKit.
    static func describe(_ error: NSError, depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)\(error.domain) Code=\(error.code): \(error.localizedDescription)"]

        for key in error.userInfo.keys.sorted() {
            guard key != NSUnderlyingErrorKey, key != partialErrorsKey else { continue }
            let value = error.userInfo[key].map { String(describing: $0) } ?? "nil"
            lines.append("\(indent)  [\(key)]: \(value)")
        }

        if let partials = error.userInfo[partialErrorsKey] as? [AnyHashable: NSError] {
            for key in partials.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
                guard let sub = partials[key] else { continue }
                lines.append("\(indent)  PartialError for \(String(describing: key)):")
                lines.append(contentsOf: describe(sub, depth: depth + 2))
            }
        } else if let partials = error.userInfo[partialErrorsKey] as? NSDictionary {
            for (key, value) in partials {
                lines.append("\(indent)  PartialDict[\(String(describing: key))]: \(String(describing: value))")
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("\(indent)  Underlying:")
            lines.append(contentsOf: describe(underlying, depth: depth + 1))
        }

        return lines
    }
}
