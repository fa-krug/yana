# Sync Log Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app diagnostics log (buffer + CloudKit event logger + viewer) to Yana's Settings on both iOS and Mac Catalyst, so an iCloud sync failure can be read on the device that is failing.

**Architecture:** A lock-protected, nonisolated in-memory ring buffer (`SyncLog`) is written to from a new `NSPersistentCloudKitContainer` event observer (`CloudKitSyncMonitor`) and from the adjacent sync services. A `SyncLogView` screen merges that buffer with a best-effort `OSLogStore` read of `com.apple.coredata` and shows a pinned diagnostics header. The screen ships in release builds but is revealed by tapping a new Version row in Settings → About five times.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData + CloudKit mirroring, `os` (`OSAllocatedUnfairLock`, `Logger`), `OSLog` (`OSLogStore`), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Source spec: `docs/superpowers/specs/2026-07-27-sync-log-viewer-design.md`. Read it before Task 1.
- Platform: iOS 26.0+ and Mac Catalyst. Every new view must compile and work in both; Mac-only code goes behind `#if targetEnvironment(macCatalyst)`.
- Swift 6 strict concurrency. `SyncLog` writes must be callable from any isolation domain — no `@MainActor` on the write path.
- Buffer capacity: **2000** entries, oldest evicted. **No file persistence, no cross-launch history.**
- `SyncLog` mirrors every entry to `Logger(subsystem: AppConstants.bundleID, category:)` with **`privacy: .public`** on every interpolation. Redaction is the bug being fixed; never emit an interpolated value without `privacy: .public`.
- CloudKit container identifier: `iCloud.de.fa-krug.Yana`.
- `CloudKitSyncMonitor.shared.start()` must be the **first statement inside the `AppContainer.shared` closure**, before `CloudKitSchemaInitializer.run()` and before any `ModelContainer` is created.
- **Never log secrets.** `KeychainService` is not instrumented; no API keys, tokens, or article bodies in log messages.
- Log *messages* stay English (diagnostic payload). Every new *UI* string goes into `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state": "translated"`, in Apple's infinitive style ("Protokoll kopieren", "Diagnose ausblenden"), no "Du"/"Sie".
- The diagnostics unlock flag is **device-local**: add it to `AppSettings` but **not** to `AppSettings.SyncedSettings`, `exportSyncedSettings()`, or `applySyncedSettings(_:)`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) in `YanaTests/`, matching `YanaTests/CloudKitSchemaCompatibilityTests.swift`.
- New files under `Yana/` are picked up automatically by XcodeGen (the target globs the `Yana` directory), but `xcodegen generate` must be re-run before building.
- Build/test command used throughout:
  `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
  A `Mach -308` / "test runner failed to launch" result is a known flake — shut down simulators and retry, it is not a real failure.
- Commit after every task.

---

## File Structure

**Create:**

| File | Responsibility |
| --- | --- |
| `Yana/Services/SyncLog.swift` | The ring buffer: `Entry`, `Level`, `Source`, nonisolated writes, `snapshot()`, `exportText(_:)` |
| `Yana/Services/CloudKitSyncMonitor.swift` | Mirroring-event observer + the pure recursive `NSError` describer + last-success/last-error state |
| `Yana/Services/SystemLogReader.swift` | Best-effort `OSLogStore` read of `com.apple.coredata`, mapped to `SyncLog.Entry` |
| `Yana/Services/SyncDiagnostics.swift` | The status-header snapshot: account status, environment, counts, last success/error |
| `Yana/Utilities/AppInfo.swift` | Bundle version/build display string |
| `Yana/Views/Config/Settings/SyncLogFilter.swift` | Pure filter over `[SyncLog.Entry]` (text/level/source) |
| `Yana/Views/Config/Settings/DiagnosticsReveal.swift` | Pure five-taps-in-three-seconds state machine |
| `Yana/Views/Config/Settings/SyncLogHeaderView.swift` | Renders a `SyncDiagnostics` |
| `Yana/Views/Config/Settings/SyncLogRow.swift` | Renders one `SyncLog.Entry` |
| `Yana/Views/Config/Settings/SyncLogView.swift` | The screen: header + filter bar + list + copy/share/hide |
| `YanaTests/SyncLogTests.swift` | Buffer behaviour + export formatting |
| `YanaTests/CloudKitSyncMonitorTests.swift` | The `NSError` describer + phase naming |
| `YanaTests/SystemLogReaderTests.swift` | Level mapping |
| `YanaTests/SyncDiagnosticsTests.swift` | Account-status/environment mapping + row counts |
| `YanaTests/SyncLogFilterTests.swift` | Filter semantics |
| `YanaTests/DiagnosticsRevealTests.swift` | Reveal state machine |
| `YanaTests/AppSettingsDiagnosticsTests.swift` | `diagnosticsUnlocked` default + never-synced |

**Modify:**

| File | Change |
| --- | --- |
| `Yana/YanaApp.swift` | `CloudKitSyncMonitor.shared.start()` first inside the `AppContainer.shared` closure |
| `Yana/Models/AppSettings.swift` | `diagnosticsUnlocked` device-local pref |
| `Yana/Services/ImageSync.swift` | Log registrations + materialisation |
| `Yana/Services/LibraryDedup.swift` | Log run + rows collapsed |
| `Yana/Services/NativeCloudKitMigration.swift` | Log what the migration did |
| `Yana/Services/LegacyCloudKitCleanup.swift` | Log deletions/retries |
| `Yana/Services/SettingsCloudSync.swift` | Log KVS push/pull/external change |
| `Yana/Services/AggregationService.swift` | Log one run summary per `updateAll()` / `update(feed:)` |
| `Yana/Services/CloudKitSchemaInitializer.swift` | Route its `NSLog`s through `SyncLog` too |
| `Yana/Views/Config/Settings/AboutSettingsSection.swift` | Version row + reveal gesture + `onRevealDiagnostics` callback |
| `Yana/Views/Config/SettingsScreenView.swift` | Diagnostics section (gated) + toast |
| `Yana/Reader/Mac/WindowID.swift` | `SettingsPane.diagnostics` case |
| `Yana/Reader/Mac/MacSettingsWindow.swift` | `visiblePanes` gating + detail branch |
| `Yana/Resources/Localizable.xcstrings` | All new UI strings + `de` |
| `CLAUDE.md` | Document the new services and the Diagnostics surface |

---

### Task 1: `SyncLog` — the ring buffer

**Files:**
- Create: `Yana/Services/SyncLog.swift`
- Test: `YanaTests/SyncLogTests.swift`

**Interfaces:**
- Consumes: `AppConstants.bundleID` from `Yana/Utilities/Constants.swift`.
- Produces:
  - `final class SyncLog: Sendable`, `static let shared: SyncLog`, `init(capacity: Int = 2000)`
  - `enum SyncLog.Level: String, Sendable, CaseIterable, Identifiable { case debug, info, notice, error }`
  - `enum SyncLog.Source: String, Sendable, CaseIterable, Identifiable { case app, system }`
  - `struct SyncLog.Entry: Identifiable, Sendable, Equatable` with `let sequence: UInt64`, `date: Date`, `level: Level`, `category: String`, `message: String`, `source: Source`, and `var id: String { "\(source.rawValue)-\(sequence)" }`
  - `func log(_ level: Level, _ category: String, _ message: String, date: Date = Date())`
  - `func debug(_:category:)`, `func info(_:category:)`, `func notice(_:category:)`, `func error(_:category:)`
  - `func snapshot() -> [Entry]` (chronological, oldest first)
  - `func clear()`
  - `static func exportText(_ entries: [Entry]) -> String`

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/SyncLogTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

struct SyncLogTests {

    @Test func logAppendsChronologicallyWithMonotonicSequence() {
        let log = SyncLog(capacity: 10)
        log.info("first", category: "CloudKit")
        log.error("second", category: "CloudKit")

        let entries = log.snapshot()
        #expect(entries.count == 2)
        #expect(entries[0].message == "first")
        #expect(entries[0].level == .info)
        #expect(entries[1].message == "second")
        #expect(entries[1].level == .error)
        #expect(entries[0].sequence < entries[1].sequence)
        #expect(entries.allSatisfy { $0.source == .app })
        #expect(entries.allSatisfy { $0.category == "CloudKit" })
    }

    @Test func capacityEvictsOldestEntriesFirst() {
        let log = SyncLog(capacity: 3)
        for index in 1...5 { log.info("entry \(index)", category: "Test") }

        let entries = log.snapshot()
        #expect(entries.count == 3)
        #expect(entries.map(\.message) == ["entry 3", "entry 4", "entry 5"])
    }

    @Test func clearRemovesEveryEntry() {
        let log = SyncLog(capacity: 10)
        log.info("gone", category: "Test")
        log.clear()
        #expect(log.snapshot().isEmpty)
    }

    @Test func concurrentWritesLoseNothingAndKeepSequencesUnique() async {
        let log = SyncLog(capacity: 1000)
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for index in 0..<50 { log.info("t\(task)-\(index)", category: "Test") }
                }
            }
        }

        let entries = log.snapshot()
        #expect(entries.count == 400)
        #expect(Set(entries.map(\.sequence)).count == 400)
    }

    @Test func exportTextEmitsOneLinePerEntryWithLevelSourceAndCategory() {
        let entry = SyncLog.Entry(
            sequence: 1,
            date: Date(timeIntervalSince1970: 0),
            level: .error,
            category: "CloudKit",
            message: "export FAILED",
            source: .app
        )

        let text = SyncLog.exportText([entry, entry])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].contains("[error]"))
        #expect(lines[0].contains("[app]"))
        #expect(lines[0].contains("[CloudKit]"))
        #expect(lines[0].contains("export FAILED"))
        #expect(lines[0].contains("1970-01-01"))
    }

    @Test func entryIDDisambiguatesSourcesWithTheSameSequence() {
        let app = SyncLog.Entry(sequence: 7, date: Date(), level: .info,
                                category: "c", message: "m", source: .app)
        let system = SyncLog.Entry(sequence: 7, date: Date(), level: .info,
                                   category: "c", message: "m", source: .system)
        #expect(app.id != system.id)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncLogTests
```

Expected: FAIL — compile error, `cannot find 'SyncLog' in scope`.

- [ ] **Step 3: Implement `SyncLog`**

Create `Yana/Services/SyncLog.swift`:

```swift
import Foundation
import os

/// In-memory diagnostic log for the iCloud/CloudKit sync path, readable inside the app via
/// `SyncLogView` (Settings → Diagnostics).
///
/// Why this exists rather than only `Logger`: SwiftData's CloudKit mirroring logs under
/// `com.apple.coredata` with the interesting values redacted to `<private>`, `OSLogStore` returns
/// only *persisted* entries (most mirroring chatter is debug/info level and therefore absent), and
/// on a locally built Mac Catalyst run `os_log` has produced a complete blackout. This buffer is the
/// one source guaranteed to have data on the device that is failing.
///
/// Concurrency: writes are `nonisolated` and serialised by an unfair lock, because mirroring events
/// arrive on an arbitrary queue in bursts and the adjacent callers (`AggregationWriter`,
/// `LibraryDeduper` — both `@ModelActor`) are off the main actor. The buffer is deliberately **not**
/// `@Observable`: a 200-event export burst would otherwise cause 200 SwiftUI invalidations. Readers
/// poll `snapshot()` instead.
///
/// History is current-launch only — there is no file persistence by design.
final class SyncLog: Sendable {
    static let shared = SyncLog()

    /// Severity, ordered loosely from least to most important. Mirrored onto `Logger` levels.
    enum Level: String, Sendable, CaseIterable, Identifiable {
        case debug, info, notice, error
        var id: String { rawValue }
    }

    /// Where an entry came from: this buffer, or the unified log via `SystemLogReader`.
    enum Source: String, Sendable, CaseIterable, Identifiable {
        case app, system
        var id: String { rawValue }
    }

    struct Entry: Identifiable, Sendable, Equatable {
        /// Monotonic within a source. Combined with `source` to form a collision-free `id`, since
        /// buffer entries and system entries are numbered independently but shown in one list.
        let sequence: UInt64
        let date: Date
        let level: Level
        let category: String
        let message: String
        let source: Source

        var id: String { "\(source.rawValue)-\(sequence)" }
    }

    /// Default retained-entry count. Oldest entries are evicted first.
    static let defaultCapacity = 2000

    private struct Storage {
        var entries: [Entry] = []
        var nextSequence: UInt64 = 1
    }

    private let capacity: Int
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    init(capacity: Int = SyncLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Append an entry. Safe to call from any isolation domain.
    func log(_ level: Level, _ category: String, _ message: String, date: Date = Date()) {
        let entry = storage.withLock { state -> Entry in
            let entry = Entry(
                sequence: state.nextSequence,
                date: date,
                level: level,
                category: category,
                message: message,
                source: .app
            )
            state.nextSequence += 1
            state.entries.append(entry)
            if state.entries.count > capacity {
                state.entries.removeFirst(state.entries.count - capacity)
            }
            return entry
        }
        Self.emitToUnifiedLog(entry)
    }

    func debug(_ message: String, category: String) { log(.debug, category, message) }
    func info(_ message: String, category: String) { log(.info, category, message) }
    func notice(_ message: String, category: String) { log(.notice, category, message) }
    func error(_ message: String, category: String) { log(.error, category, message) }

    /// Chronological snapshot, oldest first.
    func snapshot() -> [Entry] { storage.withLock { $0.entries } }

    func clear() { storage.withLock { $0.entries.removeAll() } }

    /// One line per entry, suitable for the clipboard or a shared `.txt`.
    static func exportText(_ entries: [Entry]) -> String {
        entries.map { entry in
            let stamp = ISO8601DateFormatter.string(
                from: entry.date,
                timeZone: .current,
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            )
            return "[\(stamp)] [\(entry.level.rawValue)] [\(entry.source.rawValue)] [\(entry.category)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    /// Mirror to the unified log so Console and `log stream` still work with a cable attached.
    /// `privacy: .public` on every interpolation is the whole point — redaction is the problem
    /// this feature exists to solve.
    private static func emitToUnifiedLog(_ entry: Entry) {
        let logger = Logger(subsystem: AppConstants.bundleID, category: entry.category)
        switch entry.level {
        case .debug: logger.debug("\(entry.message, privacy: .public)")
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .notice: logger.notice("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncLogTests
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/SyncLog.swift YanaTests/SyncLogTests.swift
git commit -m "Add SyncLog in-memory diagnostic ring buffer"
```

---

### Task 2: `CloudKitSyncMonitor` — the event logger

**Files:**
- Create: `Yana/Services/CloudKitSyncMonitor.swift`
- Test: `YanaTests/CloudKitSyncMonitorTests.swift`
- Modify: `Yana/YanaApp.swift` (first statement inside the `AppContainer.shared` closure, currently around line 15)

**Interfaces:**
- Consumes: `SyncLog` from Task 1 (`log(_:_:_:)`, `error(_:category:)`, `info(_:category:)`, `notice(_:category:)`, `debug(_:category:)`).
- Produces:
  - `final class CloudKitSyncMonitor: Sendable`, `static let shared`, `init(log: SyncLog = .shared)`
  - `static let category = "CloudKit"`
  - `func start()` — idempotent
  - `func lastImportSucceededAt() -> Date?`, `func lastExportSucceededAt() -> Date?`, `func lastErrorSummary() -> String?`
  - `static func describe(_ error: NSError, depth: Int = 0) -> [String]`
  - `static func phaseName(_ type: NSPersistentCloudKitContainer.EventType) -> String`

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/CloudKitSyncMonitorTests.swift`:

```swift
import CoreData
import Foundation
import Testing
@testable import Yana

struct CloudKitSyncMonitorTests {

    @Test func describeIncludesDomainCodeAndMessage() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Not Authenticated"]
        )

        let lines = CloudKitSyncMonitor.describe(error)
        #expect(lines.first?.contains("CKErrorDomain") == true)
        #expect(lines.first?.contains("Code=9") == true)
        #expect(lines.first?.contains("Not Authenticated") == true)
    }

    @Test func describeListsUserInfoKeysExceptTheOnesItRecursesInto() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 11,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                "ServerErrorDescription": "record to insert already exists",
            ]
        )

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("[ServerErrorDescription]"))
        #expect(joined.contains("record to insert already exists"))
    }

    @Test func describeRecursesIntoUnderlyingError() {
        let underlying = NSError(domain: "NSCocoaErrorDomain", code: 134400,
                                 userInfo: [NSLocalizedDescriptionKey: "Mirroring unavailable"])
        let error = NSError(domain: "CKErrorDomain", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Internal error",
                                NSUnderlyingErrorKey: underlying,
                            ])

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("Underlying:"))
        #expect(joined.contains("NSCocoaErrorDomain Code=134400"))
        #expect(joined.contains("Mirroring unavailable"))
    }

    @Test func describeRecursesIntoPartialErrors() {
        let partial = NSError(domain: "CKErrorDomain", code: 14,
                              userInfo: [NSLocalizedDescriptionKey: "Server record changed"])
        let error = NSError(domain: "CKErrorDomain", code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Partial failure",
                                "CKPartialErrors": ["Article-42": partial],
                            ])

        let joined = CloudKitSyncMonitor.describe(error).joined(separator: "\n")
        #expect(joined.contains("PartialError for Article-42:"))
        #expect(joined.contains("CKErrorDomain Code=14"))
        #expect(joined.contains("Server record changed"))
    }

    @Test func describeIndentsNestedLevels() throws {
        let underlying = NSError(domain: "Inner", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "inner"])
        let error = NSError(domain: "Outer", code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "outer",
                                NSUnderlyingErrorKey: underlying,
                            ])

        let lines = CloudKitSyncMonitor.describe(error)
        let innerLine = try #require(lines.first { $0.contains("Inner Code=1") })
        #expect(innerLine.hasPrefix("  "))
        #expect(lines[0].hasPrefix(" ") == false)
    }

    @Test func phaseNameCoversEveryEventType() {
        #expect(CloudKitSyncMonitor.phaseName(.setup) == "setup")
        #expect(CloudKitSyncMonitor.phaseName(.import) == "import")
        #expect(CloudKitSyncMonitor.phaseName(.export) == "export")
    }

    @Test func startIsIdempotentAndLogsOnce() {
        let log = SyncLog(capacity: 50)
        let monitor = CloudKitSyncMonitor(log: log)
        monitor.start()
        monitor.start()

        let starts = log.snapshot().filter { $0.message.contains("Sync monitor started") }
        #expect(starts.count == 1)
    }
}
```

Note on `try!  #require` inside a non-throwing `@Test`: declare that test as `@Test func describeIndentsNestedLevels() throws` and use `try #require(...)` instead. Write it as `throws`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CloudKitSyncMonitorTests
```

Expected: FAIL — `cannot find 'CloudKitSyncMonitor' in scope`.

- [ ] **Step 3: Implement `CloudKitSyncMonitor`**

Create `Yana/Services/CloudKitSyncMonitor.swift`:

```swift
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
        state.withLock { state in
            switch event.type {
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CloudKitSyncMonitorTests
```

Expected: PASS, 7 tests. Note `describeIndentsNestedLevels` is declared `throws` because it uses
`try #require`.

If the compiler rejects the notification closures under strict concurrency (`Notification` is not `Sendable`), keep every use of `notification`/`event` **inside** the closure body — as written — and if a diagnostic persists, annotate the closures `@Sendable`. Do not move the work to `@MainActor`: the write path must stay off the main actor.

- [ ] **Step 5: Wire `start()` into the container closure**

In `Yana/YanaApp.swift`, inside `AppContainer.shared`'s closure, the `do` block currently opens with
`return try StartupTrace.measure("ModelContainer.init") {`. Insert the monitor start immediately
**before** that `return`, so it runs before any container exists:

```swift
    static let shared: ModelContainer = {
        // Install the CloudKit mirroring-event observer BEFORE any container is created. Setup
        // events fire during `ModelContainer.init` and are where container/entitlement/account
        // failures surface — an observer installed afterwards misses exactly those events.
        CloudKitSyncMonitor.shared.start()
        do {
            return try StartupTrace.measure("ModelContainer.init") {
```

- [ ] **Step 6: Build and run the whole suite**

```bash
xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: build succeeds, all existing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/CloudKitSyncMonitor.swift YanaTests/CloudKitSyncMonitorTests.swift Yana/YanaApp.swift
git commit -m "Log CloudKit mirroring events with the full error tree"
```

---

### Task 3: `SystemLogReader` — the `OSLogStore` supplement

**Files:**
- Create: `Yana/Services/SystemLogReader.swift`
- Test: `YanaTests/SystemLogReaderTests.swift`

**Interfaces:**
- Consumes: `SyncLog.Entry`, `SyncLog.Level`, `SyncLog.Source` from Task 1.
- Produces:
  - `enum SystemLogReader`
  - `static let coreDataSubsystem = "com.apple.coredata"`
  - `nonisolated static func fetch(since: Date) async -> [SyncLog.Entry]`
  - `static func level(for level: OSLogEntryLog.Level) -> SyncLog.Level`
  - `static let logWindowStart: Date` — a deliberately-early lower bound for a fetch (the system
    boot instant). Note `ProcessInfo.systemUptime` measures time since the **device** booted, not
    since this process started, so this is earlier than launch — which is safe and sufficient,
    because `OSLogStore(scope: .currentProcessIdentifier)` already restricts results to this
    process and the bound only has to be early enough to miss nothing.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/SystemLogReaderTests.swift`:

```swift
import Foundation
import OSLog
import Testing
@testable import Yana

struct SystemLogReaderTests {

    @Test func mapsOSLogLevelsOntoSyncLogLevels() {
        #expect(SystemLogReader.level(for: .debug) == .debug)
        #expect(SystemLogReader.level(for: .info) == .info)
        #expect(SystemLogReader.level(for: .notice) == .notice)
        #expect(SystemLogReader.level(for: .error) == .error)
        #expect(SystemLogReader.level(for: .fault) == .error)
        #expect(SystemLogReader.level(for: .undefined) == .info)
    }
}
```

There is deliberately **no** test calling `fetch(since:)`: the unified log legitimately returns
nothing for the current process most of the time, so any assertion over its result passes vacuously.
The fetch path is covered by the manual verification step at the end of this plan instead.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SystemLogReaderTests
```

Expected: FAIL — `cannot find 'SystemLogReader' in scope`.

- [ ] **Step 3: Implement `SystemLogReader`**

Create `Yana/Services/SystemLogReader.swift`:

```swift
import Foundation
import OSLog

/// Best-effort read of the unified log for CoreData/CloudKit mirroring entries belonging to this
/// process, merged into the diagnostics view alongside `SyncLog`'s own buffer.
///
/// Deliberately a *supplement*, not the primary source. `OSLogStore` returns only **persisted**
/// entries; most mirroring chatter is debug/info level and therefore often absent, and on a locally
/// built Mac Catalyst run this can come back completely empty. `SyncLog` is the guaranteed source —
/// this adds Apple's side of the story where it happens to be available.
enum SystemLogReader {
    /// CoreData's subsystem — where `NSPersistentCloudKitContainer` logs its mirroring activity.
    ///
    /// Only this subsystem is matched, deliberately: `SyncLog` mirrors every buffer entry to
    /// `Logger(subsystem: AppConstants.bundleID)`, so also matching Yana's own subsystem would show
    /// each app entry twice in the merged list.
    static let coreDataSubsystem = "com.apple.coredata"

    /// A deliberately-early lower bound for a fetch: the system boot instant.
    ///
    /// `ProcessInfo.systemUptime` measures time since the **device** last booted, not since this
    /// process started, so this is earlier than launch. That is safe and sufficient — `OSLogStore`
    /// here is scoped to the current process, so entries from before launch cannot match, and the
    /// bound only has to be early enough to miss nothing.
    static let logWindowStart = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)

    /// Fetch mirroring entries logged since `since`.
    ///
    /// `nonisolated async` on purpose: `OSLogStore.getEntries` is synchronous and can take a while,
    /// and a nonisolated async function runs on the concurrent executor rather than the caller's
    /// actor — so calling this from the main actor does not block it.
    nonisolated static func fetch(since: Date) async -> [SyncLog.Entry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", coreDataSubsystem)

            var results: [SyncLog.Entry] = []
            var sequence: UInt64 = 0
            for case let entry as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
                results.append(SyncLog.Entry(
                    sequence: sequence,
                    date: entry.date,
                    level: level(for: entry.level),
                    category: entry.category.isEmpty ? "coredata" : entry.category,
                    message: entry.composedMessage,
                    source: .system
                ))
                sequence += 1
            }
            return results
        } catch {
            // Surface the failure as an entry rather than silently returning nothing — an empty
            // viewer must never leave you guessing whether there was nothing to show or no way to
            // look.
            return [SyncLog.Entry(
                sequence: 0,
                date: Date(),
                level: .error,
                category: "diagnostics",
                message: "Could not read the system log: \(error.localizedDescription)",
                source: .system
            )]
        }
    }

    static func level(for level: OSLogEntryLog.Level) -> SyncLog.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .error, .fault: .error
        case .undefined: .info
        @unknown default: .info
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SystemLogReaderTests
```

Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/SystemLogReader.swift YanaTests/SystemLogReaderTests.swift
git commit -m "Read CoreData mirroring entries from the unified log"
```

---

### Task 4: Instrument the sync-adjacent services

**Files:**
- Modify: `Yana/Services/ImageSync.swift`, `Yana/Services/LibraryDedup.swift`,
  `Yana/Services/NativeCloudKitMigration.swift`, `Yana/Services/LegacyCloudKitCleanup.swift`,
  `Yana/Services/SettingsCloudSync.swift`, `Yana/Services/AggregationService.swift`,
  `Yana/Services/CloudKitSchemaInitializer.swift`

**Interfaces:**
- Consumes: `SyncLog.shared.info/notice/error(_:category:)` from Task 1.
- Produces: nothing new. Categories used by later tasks' expectations: `"ImageSync"`, `"Dedup"`,
  `"Migration"`, `"Cleanup"`, `"Settings"`, `"Aggregation"`, `"Schema"`.

No new tests: these are single log lines on existing code paths, and the existing suite guards the
behaviour around them. The gate for this task is that the full suite still passes.

- [ ] **Step 1: Instrument `ImageSync`**

In `Yana/Services/ImageSync.swift`, in `ensureStored(hashes:context:imageStore:)`, replace the
`if inserted { try? context.save() }` tail with a counted version:

```swift
        var insertedCount = 0
        for hash in hashes where !existing.contains(hash) {
            guard let bytes = await imageStore.rawData(forHash: hash) else { continue }
            let ext = await imageStore.recordedExt(forHash: hash)
            context.insert(StoredImage(contentHash: hash, data: bytes, ext: ext))
            insertedCount += 1
        }
        if insertedCount > 0 {
            try? context.save()
            SyncLog.shared.info("Registered \(insertedCount) StoredImage row(s) for sync", category: "ImageSync")
        }
```

(the local `var inserted = false` flag is replaced by `insertedCount`; remove it).

And in `materialize(hash:context:imageStore:)`, log the cache-miss path — after the successful
`storeData` call, before `return true`:

```swift
        _ = await imageStore.storeData(stored.data, ext: stored.ext)
        SyncLog.shared.info("Materialized synced image \(hash) into the disk cache", category: "ImageSync")
        return true
```

- [ ] **Step 2: Instrument `LibraryDedup`**

In `Yana/Services/LibraryDedup.swift`, `LibraryDeduper.deduplicate()` returns the deleted count.
Log inside it, just before `return deleted`:

```swift
        if deleted > 0 { try modelContext.save() }
        if deleted > 0 {
            SyncLog.shared.notice("Dedup collapsed \(deleted) duplicate row(s)", category: "Dedup")
        }
        return deleted
```

And in `LibraryDedup.startObserving(container:)`, log that the observer is armed, right after the
coalescer is stored:

```swift
        self.coalescer = coalescer
        SyncLog.shared.info("Watching for CloudKit remote-change merges", category: "Dedup")
```

- [ ] **Step 3: Instrument the migration and cleanup services**

Read `Yana/Services/NativeCloudKitMigration.swift` and `Yana/Services/LegacyCloudKitCleanup.swift`
first. In `NativeCloudKitMigration.runIfNeeded(...)`, add one line where it decides to skip and one
where it completes:

```swift
        // where the already-migrated early return happens:
        SyncLog.shared.info("Native CloudKit migration already done — skipping", category: "Migration")
        // at the end of a successful run, before the flag is set:
        SyncLog.shared.notice("Native CloudKit migration finished", category: "Migration")
```

In `LegacyCloudKitCleanup.runIfNeeded(...)`, log the outcome of each deletion attempt at the points
where it already branches on success/failure:

```swift
        SyncLog.shared.info("Legacy CloudKit cleanup succeeded", category: "Cleanup")
        // and on the failure/retry branch:
        SyncLog.shared.notice("Legacy CloudKit cleanup deferred: \(error.localizedDescription)", category: "Cleanup")
```

Match the existing control flow rather than restructuring it — add lines only.

- [ ] **Step 4: Instrument `SettingsCloudSync`**

In `Yana/Services/SettingsCloudSync.swift`:

```swift
    static func push(_ settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed else { return }
        store.set(settings.exportSyncedSettings(), forKey: key)
        store.synchronize()
        SyncLog.shared.info("Pushed synced settings to iCloud key-value store", category: "Settings")
    }

    static func pull(into settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed, let data = store.data(forKey: key) else { return }
        settings.applySyncedSettings(data)
        SyncLog.shared.info("Applied \(data.count) bytes of synced settings from iCloud", category: "Settings")
    }
```

and inside the `didChangeExternallyNotification` observer in `start(_:)`:

```swift
        ) { _ in
            MainActor.assumeIsolated {
                SyncLog.shared.info("Synced settings changed on another device", category: "Settings")
                pull(into: settings)
            }
        }
```

- [ ] **Step 5: Instrument `AggregationService`**

In `Yana/Services/AggregationService.swift`, `updateAll()` — after `lastRunFailures = result.failures`:

```swift
        lastRunFailures = result.failures
        SyncLog.shared.info(
            "updateAll inserted \(result.inserted) article(s); \(result.failures.count) feed failure(s)",
            category: "Aggregation"
        )
```

and the same in `update(feed:)`, using the feed's name:

```swift
        lastRunFailures = result.failures
        SyncLog.shared.info(
            "update(\(feed.name)) inserted \(result.inserted) article(s); \(result.failures.count) failure(s)",
            category: "Aggregation"
        )
```

Verify the property is named `feed.name` when writing this; if the model calls it something else,
use the actual property.

- [ ] **Step 6: Instrument `CloudKitSchemaInitializer`**

In `Yana/Services/CloudKitSchemaInitializer.swift`, keep the existing `NSLog` calls (they are the
only thing visible in a directly launched Catalyst run) and add a matching `SyncLog` line beside each,
so the same information reaches the in-app viewer. Example for the success path:

```swift
            NSLog("CloudKitSchemaInitializer: Development schema initialized for \(containerIdentifier)")
            SyncLog.shared.notice("Development schema initialized for \(containerIdentifier)", category: "Schema")
```

Do the same for the two failure paths and the "could not build managed object model" path, using
`SyncLog.shared.error(...)` for those.

- [ ] **Step 7: Run the full suite**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: PASS — every pre-existing test unchanged.

- [ ] **Step 8: Commit**

```bash
git add Yana/Services
git commit -m "Log the sync-adjacent services into SyncLog"
```

---

### Task 5: `SyncDiagnostics` — the status header snapshot

**Files:**
- Create: `Yana/Services/SyncDiagnostics.swift`, `Yana/Utilities/AppInfo.swift`
- Test: `YanaTests/SyncDiagnosticsTests.swift`

**Interfaces:**
- Consumes: `CloudKitSyncMonitor.shared.lastImportSucceededAt()/lastExportSucceededAt()/lastErrorSummary()` from Task 2.
- Produces:
  - `enum AppInfo` with `static var version: String`, `static var build: String`, `static var versionDisplay: String`
  - `struct SyncDiagnostics: Sendable` with stored properties `accountStatus: String`,
    `containerIdentifier: String`, `environment: String`, `appVersion: String`,
    `systemVersion: String`, `idiom: String`, `feedCount: Int`, `tagCount: Int`,
    `articleCount: Int`, `storedImageCount: Int`, `lastImportSucceededAt: Date?`,
    `lastExportSucceededAt: Date?`, `lastErrorSummary: String?`
  - `static let containerIdentifier = "iCloud.de.fa-krug.Yana"`
  - `static var environment: String` — `"Development"` in DEBUG, `"Production"` otherwise
  - `static func describe(_ status: CKAccountStatus) -> String`
  - `@MainActor static func make(context: ModelContext, monitor: CloudKitSyncMonitor = .shared) async -> SyncDiagnostics`

**Note on a spec deviation:** the spec said the environment is derived from the build configuration
*and* the `aps-environment` entitlement value. The entitlement lives in the code signature and is not
reliably readable at runtime from the app bundle, so this implements build-configuration derivation
only (DEBUG → Development, otherwise Production), which is the same conclusion for every real build
path Yana ships. Say so in the header UI copy: the value is labelled from the build configuration.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/SyncDiagnosticsTests.swift`:

```swift
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
```

Check `Tag`'s initialiser signature in `Yana/Models/Tag.swift` before writing this and use the real
one (`TestHelper.swift` in `YanaTests/` may already have a factory — prefer it if so).

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncDiagnosticsTests
```

Expected: FAIL — `cannot find 'SyncDiagnostics' in scope`.

- [ ] **Step 3: Implement `AppInfo`**

Create `Yana/Utilities/AppInfo.swift`:

```swift
import Foundation

/// Bundle version information, for the Settings → About version row and the diagnostics header.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// e.g. `1.1.0 (1)`.
    static var versionDisplay: String { "\(version) (\(build))" }
}
```

- [ ] **Step 4: Implement `SyncDiagnostics`**

Create `Yana/Services/SyncDiagnostics.swift`:

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncDiagnosticsTests
```

Expected: PASS, 4 tests. If `CKContainer(identifier:).accountStatus()` is slow in the simulator the
`make` test may take a couple of seconds — that is fine; it must not hang or throw.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/SyncDiagnostics.swift Yana/Utilities/AppInfo.swift YanaTests/SyncDiagnosticsTests.swift
git commit -m "Add SyncDiagnostics snapshot for the log header"
```

---

### Task 6: `SyncLogFilter` and `DiagnosticsReveal` — the pure view logic

**Files:**
- Create: `Yana/Views/Config/Settings/SyncLogFilter.swift`,
  `Yana/Views/Config/Settings/DiagnosticsReveal.swift`
- Test: `YanaTests/SyncLogFilterTests.swift`, `YanaTests/DiagnosticsRevealTests.swift`

**Interfaces:**
- Consumes: `SyncLog.Entry`, `SyncLog.Level`, `SyncLog.Source` from Task 1.
- Produces:
  - `struct SyncLogFilter: Equatable, Sendable` with `var text: String = ""`,
    `var level: SyncLog.Level?` (nil = all), `var source: SyncLog.Source?` (nil = all),
    and `func apply(to entries: [SyncLog.Entry]) -> [SyncLog.Entry]`
  - `enum DiagnosticsReveal` with `static let requiredTaps = 5`, `static let window: TimeInterval = 3`,
    `struct State: Equatable { var firstTapAt: Date?; var count: Int }` (init `State()` gives
    `nil`/`0`), and
    `static func register(_ state: State, at now: Date) -> (state: State, unlocked: Bool)`

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/SyncLogFilterTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

struct SyncLogFilterTests {

    private func entry(
        _ sequence: UInt64,
        _ level: SyncLog.Level,
        _ category: String,
        _ message: String,
        _ source: SyncLog.Source = .app
    ) -> SyncLog.Entry {
        SyncLog.Entry(sequence: sequence, date: Date(timeIntervalSince1970: TimeInterval(sequence)),
                      level: level, category: category, message: message, source: source)
    }

    private var sample: [SyncLog.Entry] {
        [
            entry(1, .info, "CloudKit", "export succeeded"),
            entry(2, .error, "CloudKit", "export FAILED"),
            entry(3, .info, "Dedup", "Dedup collapsed 3 duplicate row(s)"),
            entry(4, .notice, "coredata", "mirroring started", .system),
        ]
    }

    @Test func emptyFilterReturnsEverythingUnchanged() {
        #expect(SyncLogFilter().apply(to: sample).map(\.sequence) == [1, 2, 3, 4])
    }

    @Test func levelFilterMatchesExactly() {
        var filter = SyncLogFilter()
        filter.level = .error
        #expect(filter.apply(to: sample).map(\.sequence) == [2])
    }

    @Test func sourceFilterSeparatesAppFromSystem() {
        var filter = SyncLogFilter()
        filter.source = .system
        #expect(filter.apply(to: sample).map(\.sequence) == [4])
    }

    @Test func textFilterMatchesMessageOrCategoryCaseInsensitively() {
        var filter = SyncLogFilter()
        filter.text = "DEDUP"
        #expect(filter.apply(to: sample).map(\.sequence) == [3])

        filter.text = "failed"
        #expect(filter.apply(to: sample).map(\.sequence) == [2])
    }

    @Test func filtersCombineWithAndSemantics() {
        var filter = SyncLogFilter()
        filter.level = .info
        filter.text = "export"
        #expect(filter.apply(to: sample).map(\.sequence) == [1])
    }
}
```

Create `YanaTests/DiagnosticsRevealTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

struct DiagnosticsRevealTests {

    @Test func firstTapStartsTheWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let result = DiagnosticsReveal.register(DiagnosticsReveal.State(), at: now)
        #expect(result.state.count == 1)
        #expect(result.state.firstTapAt == now)
        #expect(result.unlocked == false)
    }

    @Test func fiveTapsInsideTheWindowUnlock() {
        var state = DiagnosticsReveal.State()
        var unlocked = false
        for step in 0..<5 {
            let result = DiagnosticsReveal.register(
                state, at: Date(timeIntervalSince1970: 1000 + Double(step) * 0.4)
            )
            state = result.state
            unlocked = result.unlocked
        }
        #expect(unlocked)
        #expect(state.count == 5)
    }

    @Test func fourTapsDoNotUnlock() {
        var state = DiagnosticsReveal.State()
        var unlocked = false
        for step in 0..<4 {
            let result = DiagnosticsReveal.register(
                state, at: Date(timeIntervalSince1970: 1000 + Double(step) * 0.4)
            )
            state = result.state
            unlocked = result.unlocked
        }
        #expect(unlocked == false)
    }

    @Test func aTapAfterTheWindowRestartsCounting() {
        var state = DiagnosticsReveal.State()
        for step in 0..<3 {
            state = DiagnosticsReveal.register(
                state, at: Date(timeIntervalSince1970: 1000 + Double(step) * 0.4)
            ).state
        }
        #expect(state.count == 3)

        // 10s later — outside the 3s window.
        let result = DiagnosticsReveal.register(state, at: Date(timeIntervalSince1970: 1010))
        #expect(result.state.count == 1)
        #expect(result.unlocked == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncLogFilterTests -only-testing:YanaTests/DiagnosticsRevealTests
```

Expected: FAIL — `cannot find 'SyncLogFilter' in scope`, `cannot find 'DiagnosticsReveal' in scope`.

- [ ] **Step 3: Implement `SyncLogFilter`**

Create `Yana/Views/Config/Settings/SyncLogFilter.swift`:

```swift
import Foundation

/// The diagnostics log's filter, kept as a pure value so the matching rules are unit-tested without
/// standing up SwiftUI. `nil` level/source mean "all"; filters combine with AND.
struct SyncLogFilter: Equatable, Sendable {
    var text: String = ""
    var level: SyncLog.Level?
    var source: SyncLog.Source?

    func apply(to entries: [SyncLog.Entry]) -> [SyncLog.Entry] {
        entries.filter { entry in
            if let level, entry.level != level { return false }
            if let source, entry.source != source { return false }
            guard !text.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(text)
                || entry.category.localizedCaseInsensitiveContains(text)
        }
    }
}
```

- [ ] **Step 4: Implement `DiagnosticsReveal`**

Create `Yana/Views/Config/Settings/DiagnosticsReveal.swift`:

```swift
import Foundation

/// The "tap the version row five times" gesture that reveals the diagnostics log.
///
/// The log ships in release builds — it is the only way to see why sync fails on a TestFlight or App
/// Store build talking to the Production CloudKit environment — but it is not a feature users need,
/// so it stays out of the way until asked for. Pure state machine, so the timing rules are tested
/// without a UI.
enum DiagnosticsReveal {
    static let requiredTaps = 5
    static let window: TimeInterval = 3

    struct State: Equatable {
        var firstTapAt: Date?
        var count: Int = 0
    }

    /// Fold a tap at `now` into `state`. Returns the new state and whether the gesture completed.
    /// A tap more than `window` seconds after the first restarts the count at 1.
    static func register(_ state: State, at now: Date) -> (state: State, unlocked: Bool) {
        guard let firstTapAt = state.firstTapAt,
              now.timeIntervalSince(firstTapAt) <= window
        else {
            return (State(firstTapAt: now, count: 1), false)
        }

        let count = state.count + 1
        return (State(firstTapAt: firstTapAt, count: count), count >= requiredTaps)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncLogFilterTests -only-testing:YanaTests/DiagnosticsRevealTests
```

Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/Settings/SyncLogFilter.swift Yana/Views/Config/Settings/DiagnosticsReveal.swift YanaTests/SyncLogFilterTests.swift YanaTests/DiagnosticsRevealTests.swift
git commit -m "Add pure log-filter and reveal-gesture logic"
```

---

### Task 7: The viewer — `SyncLogView`, row, and header

**Files:**
- Create: `Yana/Views/Config/Settings/SyncLogRow.swift`,
  `Yana/Views/Config/Settings/SyncLogHeaderView.swift`,
  `Yana/Views/Config/Settings/SyncLogView.swift`

**Interfaces:**
- Consumes: `SyncLog.shared.snapshot()`, `SyncLog.exportText(_:)` (Task 1);
  `SystemLogReader.fetch(since:)`, `SystemLogReader.logWindowStart` (Task 3);
  `SyncDiagnostics.make(context:)` (Task 5); `SyncLogFilter` (Task 6).
- Produces:
  - `struct SyncLogRow: View { let entry: SyncLog.Entry }`
  - `struct SyncLogHeaderView: View { let diagnostics: SyncDiagnostics }`
  - `struct SyncLogView: View { var onHideDiagnostics: () -> Void = {} }`
  - `struct SyncLogDocument: Transferable { let text: String }`

There is no unit test for these views — the logic they depend on is already covered by Tasks 1, 5,
and 6. The gate is that the app builds for both destinations and the screen renders.

- [ ] **Step 1: Implement the row**

Create `Yana/Views/Config/Settings/SyncLogRow.swift`:

```swift
import SwiftUI

/// One diagnostics log entry: level glyph, category, timestamp, and the message in a monospaced
/// selectable font.
struct SyncLogRow: View {
    let entry: SyncLog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: levelIcon)
                    .foregroundStyle(levelColor)
                    .font(.caption)
                Text(entry.category)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                if entry.source == .system {
                    Text(verbatim: "sys")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var levelIcon: String {
        switch entry.level {
        case .error: "exclamationmark.triangle.fill"
        case .notice: "bell.fill"
        case .info: "info.circle.fill"
        case .debug: "ant.fill"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .error: .red
        case .notice: .orange
        case .info: .blue
        case .debug: .gray
        }
    }
}
```

- [ ] **Step 2: Implement the header**

Create `Yana/Views/Config/Settings/SyncLogHeaderView.swift`:

```swift
import SwiftUI

/// The pinned diagnostics summary above the log. Answers the two questions that explain most sync
/// failures — is there an iCloud account, and which CloudKit environment is this build talking to —
/// before any log line is read.
struct SyncLogHeaderView: View {
    let diagnostics: SyncDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("iCloud Account", diagnostics.accountStatus)
            row("Container", diagnostics.containerIdentifier)
            row("Environment", diagnostics.environment)
            row("App", diagnostics.appVersion)
            row("System", "\(diagnostics.systemVersion) · \(diagnostics.idiom)")
            row("Library", "\(diagnostics.feedCount) feeds · \(diagnostics.tagCount) tags · \(diagnostics.articleCount) articles · \(diagnostics.storedImageCount) images")
            row("Last Import", stamp(diagnostics.lastImportSucceededAt))
            row("Last Export", stamp(diagnostics.lastExportSucceededAt))
            if let error = diagnostics.lastErrorSummary {
                Text("Last Error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
```

- [ ] **Step 3: Implement the screen**

Create `Yana/Views/Config/Settings/SyncLogView.swift`:

```swift
import CoreTransferable
import SwiftData
import SwiftUI
import UIKit

/// The diagnostics log screen: a pinned status header, a filter bar, and the merged entry list
/// (`SyncLog`'s own buffer plus whatever `SystemLogReader` can see of CoreData's mirroring lines).
///
/// Refreshes on a 1 s tick while visible rather than observing `SyncLog`, because a CloudKit export
/// burst produces hundreds of entries in a second and per-entry SwiftUI invalidation would make the
/// screen unusable exactly when it matters.
struct SyncLogView: View {
    /// Called when the user chooses to hide diagnostics again, so the presenting settings surface can
    /// drop its Diagnostics entry (each settings screen owns its own `AppSettings` instance, so the
    /// flag change has to be handed back rather than observed).
    var onHideDiagnostics: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    @State private var entries: [SyncLog.Entry] = []
    @State private var filter = SyncLogFilter()
    @State private var diagnostics: SyncDiagnostics?
    @State private var isHeaderExpanded = true
    @State private var toast: ToastMessage?
    /// Scroll to the newest entry once, on the first load. Not on every 1 s tick — that would yank
    /// the list out from under you while reading.
    @State private var hasScrolledToNewest = false

    private var visibleEntries: [SyncLog.Entry] { filter.apply(to: entries) }

    private var exportText: String { SyncLog.exportText(visibleEntries) }

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy: proxy)
        }
    }

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                DisclosureGroup(isExpanded: $isHeaderExpanded) {
                    if let diagnostics {
                        SyncLogHeaderView(diagnostics: diagnostics)
                    } else {
                        ProgressView()
                    }
                } label: {
                    Label("Sync Status", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
            }

            Section {
                TextField("Filter", text: $filter.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Level", selection: $filter.level) {
                    Text("All").tag(SyncLog.Level?.none)
                    ForEach(SyncLog.Level.allCases) { level in
                        Text(level.rawValue.capitalized).tag(SyncLog.Level?.some(level))
                    }
                }
                Picker("Source", selection: $filter.source) {
                    Text("All").tag(SyncLog.Source?.none)
                    Text("App").tag(SyncLog.Source?.some(.app))
                    Text("System").tag(SyncLog.Source?.some(.system))
                }
            }

            Section {
                if visibleEntries.isEmpty {
                    ContentUnavailableView(
                        "No Entries",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Nothing matches the current filter. The log covers this app launch only — the system portion shows only entries the unified log kept, which is often nothing.")
                    )
                } else {
                    ForEach(visibleEntries) { entry in
                        SyncLogRow(entry: entry)
                            .id(entry.id)
                    }
                }
            } header: {
                Text("\(visibleEntries.count) entries")
            }

            Section {
                Button(role: .destructive) {
                    onHideDiagnostics()
                } label: {
                    Label("Hide Diagnostics", systemImage: "eye.slash")
                }
            } footer: {
                Text("Hiding removes this screen from Settings. Tap the version row in About five times to bring it back.")
            }
        }
        .navigationTitle("Diagnostics")
        .toast($toast)
        .toolbar {
            ToolbarItem {
                Button {
                    UIPasteboard.general.string = exportText
                    toast = ToastMessage(text: String(localized: "Log copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(Text("Copy Log"))
                .disabled(visibleEntries.isEmpty)
            }
            ToolbarItem {
                ShareLink(
                    item: SyncLogDocument(text: exportText),
                    preview: SharePreview("Yana Sync Log")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(visibleEntries.isEmpty)
            }
        }
        .task {
            await reload()
            // Chronological list, so the interesting end is the bottom — park there once.
            if let last = visibleEntries.last {
                proxy.scrollTo(last.id, anchor: .bottom)
                hasScrolledToNewest = true
            }
            // Poll instead of observing: see the type comment.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                await reload()
                if !hasScrolledToNewest, let last = visibleEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                    hasScrolledToNewest = true
                }
            }
        }
        .accessibilityIdentifier("settings.diagnostics.log")
    }

    private func reload() async {
        let buffered = SyncLog.shared.snapshot()
        let system = await SystemLogReader.fetch(since: SystemLogReader.logWindowStart)
        entries = (buffered + system).sorted { $0.date < $1.date }
        diagnostics = await SyncDiagnostics.make(context: modelContext)
    }
}

/// Exports the log as a `.txt` attachment, so the share sheet offers Mail/Files rather than pasting
/// thousands of lines of plain text into a message body.
struct SyncLogDocument: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { document in
            Data(document.text.utf8)
        }
        .suggestedFileName("yana-sync-log.txt")
    }
}
```

Notes for the implementer:
- `String(localized:)` is the project's convention for computed strings — check its exact spelling in
  an existing file (e.g. `Yana/Views/Config/FeedsView.swift`) and match it.
- `DataRepresentation(exportedContentType: .plainText)` needs `import UniformTypeIdentifiers` if
  `.plainText` does not resolve from `CoreTransferable` alone; add it.
- The 1 s poll re-runs `SyncDiagnostics.make`, which does a `CKContainer.accountStatus()` call. If
  that turns out to be slow enough to be noticeable, refresh the diagnostics only on the first
  `reload()` and on an explicit pull-to-refresh, keeping the 1 s tick for entries only. Prefer the
  simple version first and only split if it actually stutters.

- [ ] **Step 4: Build for both destinations**

```bash
xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac-synclog build
```

Expected: both succeed. The Catalyst build only needs to **compile** — it cannot be signed or run
from an automation shell (locked keychain), so do not attempt to launch it.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/Settings/SyncLogView.swift Yana/Views/Config/Settings/SyncLogRow.swift Yana/Views/Config/Settings/SyncLogHeaderView.swift
git commit -m "Add the diagnostics log viewer"
```

---

### Task 8: The unlock pref, the Version row, and the reveal gesture

**Files:**
- Modify: `Yana/Models/AppSettings.swift`,
  `Yana/Views/Config/Settings/AboutSettingsSection.swift`
- Test: `YanaTests/AppSettingsDiagnosticsTests.swift` (create)

**Interfaces:**
- Consumes: `DiagnosticsReveal.register(_:at:)` and `DiagnosticsReveal.State` (Task 6);
  `AppInfo.versionDisplay` (Task 5).
- Produces:
  - `AppSettings.diagnosticsUnlocked: Bool` (device-local, default `false`)
  - `AboutSettingsSection`'s new parameter `var onRevealDiagnostics: () -> Void = {}`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AppSettingsDiagnosticsTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
struct AppSettingsDiagnosticsTests {

    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "AppSettingsDiagnosticsTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
    }

    @Test func diagnosticsUnlockedDefaultsToFalse() {
        #expect(makeSettings().diagnosticsUnlocked == false)
    }

    @Test func diagnosticsUnlockedPersistsToItsDefaultsStore() {
        let settings = makeSettings()
        settings.diagnosticsUnlocked = true
        #expect(settings.diagnosticsUnlocked)
    }

    @Test func diagnosticsUnlockedIsNeverSyncedToOtherDevices() throws {
        let source = makeSettings()
        source.diagnosticsUnlocked = true

        let destination = makeSettings()
        destination.applySyncedSettings(source.exportSyncedSettings())

        // Device-local by design: the flag must not ride along in the iCloud key-value payload.
        #expect(destination.diagnosticsUnlocked == false)

        let json = try #require(
            try JSONSerialization.jsonObject(with: source.exportSyncedSettings()) as? [String: Any]
        )
        #expect(json["diagnosticsUnlocked"] == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsDiagnosticsTests
```

Expected: FAIL — `value of type 'AppSettings' has no member 'diagnosticsUnlocked'`.

- [ ] **Step 3: Add the pref**

In `Yana/Models/AppSettings.swift`, add the key next to the other device-local keys in the private
`Key` enum (after `macSidebarWidth`):

```swift
        // Diagnostics (device-local, never synced)
        static let diagnosticsUnlocked = "settings.diagnosticsUnlocked"
```

and the property alongside the other device-local ones (near `macSidebarWidth`'s property):

```swift
    /// Whether the Settings → Diagnostics log is revealed on this device. Device-local and never
    /// synced: the log ships in release builds but stays hidden until the version row in About is
    /// tapped five times, and that choice should not follow the user to another device.
    var diagnosticsUnlocked: Bool {
        get { access(keyPath: \.diagnosticsUnlocked); return defaults.bool(forKey: Key.diagnosticsUnlocked) }
        set { withMutation(keyPath: \.diagnosticsUnlocked) { defaults.set(newValue, forKey: Key.diagnosticsUnlocked) } }
    }
```

Do **not** add it to `SyncedSettings`, `exportSyncedSettings()`, or `applySyncedSettings(_:)`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsDiagnosticsTests
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Add the Version row and reveal gesture**

Rewrite `Yana/Views/Config/Settings/AboutSettingsSection.swift` to add the version row, keeping every
existing row and the footer text unchanged:

```swift
import SwiftUI

/// Source/issue links, NetNewsWire credit, the app version, and the "show welcome screen again"
/// restart action.
struct AboutSettingsSection: View {
    var onRestartOnboarding: () -> Void = {}
    /// Called when the version row's five-tap gesture reveals the diagnostics log, so the presenting
    /// settings surface can show its Diagnostics entry. Each settings screen owns its own
    /// `AppSettings` instance, so the change has to be handed back rather than observed.
    var onRevealDiagnostics: () -> Void = {}

    @State private var settings = AppSettings()
    @State private var revealState = DiagnosticsReveal.State()

    var body: some View {
        Section {
            LabeledContent("Version", value: AppInfo.versionDisplay)
                .contentShape(Rectangle())
                .onTapGesture { registerVersionTap() }
                .accessibilityIdentifier("settings.version")
            Link(destination: URL(string: "https://github.com/fa-krug/yana")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.tintedIcon(.gray))
            }
            Link(destination: URL(string: "https://github.com/fa-krug/yana/issues")!) {
                Label("Suggest a Source or Report an Issue", systemImage: "exclamationmark.bubble")
                    .labelStyle(.tintedIcon(.green))
            }
            Link(destination: URL(string: "https://netnewswire.com")!) {
                Label("Reader View Inspired by NetNewsWire", systemImage: "heart")
                    .labelStyle(.tintedIcon(.pink))
            }
            Button {
                settings.hasCompletedOnboarding = false
                onRestartOnboarding()
            } label: {
                Label("Show Welcome Screen Again", systemImage: "sparkles")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.showWelcome")
        } header: {
            Text("About")
        } footer: {
            Text("Yana is free and open source. The list of built-in sources grows from what people ask for, so suggest one on the issue board. Thanks to the NetNewsWire team, whose clean reader view shaped how articles look here.")
        }
    }

    private func registerVersionTap() {
        let result = DiagnosticsReveal.register(revealState, at: Date())
        revealState = result.state
        guard result.unlocked, !settings.diagnosticsUnlocked else { return }
        settings.diagnosticsUnlocked = true
        revealState = DiagnosticsReveal.State()
        onRevealDiagnostics()
    }
}
```

- [ ] **Step 6: Build and run the full suite**

```bash
xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: PASS. If a `YanaUITests` case asserts on About's rows or scrolls with
`scrollToSettingsRow`, update it for the added Version row rather than reverting the row.

- [ ] **Step 7: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Views/Config/Settings/AboutSettingsSection.swift YanaTests/AppSettingsDiagnosticsTests.swift
git commit -m "Reveal diagnostics by tapping the new About version row"
```

---

### Task 9: Placement in iOS Settings and the Mac Settings window

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift`, `Yana/Reader/Mac/WindowID.swift`,
  `Yana/Reader/Mac/MacSettingsWindow.swift`

**Interfaces:**
- Consumes: `AppSettings.diagnosticsUnlocked` and `AboutSettingsSection.onRevealDiagnostics`
  (Task 8); `SyncLogView(onHideDiagnostics:)` (Task 7).
- Produces: `SettingsPane.diagnostics` case.

- [ ] **Step 1: Add the Diagnostics section to iOS Settings**

In `Yana/Views/Config/SettingsScreenView.swift`, add state, the gated section, and the toast:

```swift
struct SettingsScreenView: View {
    var onRestartOnboarding: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()
    @State private var toast: ToastMessage?

    var body: some View {
        Form {
            organizeSection
            ReaderSettingsSection()
            RedditSettingsSection()
            YouTubeSettingsSection()
            NotificationsSettingsSection()
            AIProviderSettingsSection()
            AITuningSettingsSection()
            LibrarySettingsSection()
            AboutSettingsSection(
                onRestartOnboarding: {
                    onRestartOnboarding()
                    dismiss()
                },
                onRevealDiagnostics: {
                    toast = ToastMessage(text: String(localized: "Diagnostics enabled"))
                }
            )
            if settings.diagnosticsUnlocked {
                diagnosticsSection
            }
        }
        .toast($toast)
        // …existing modifiers unchanged (toggleStyle, navigationTitle, toolbar)…
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                SyncLogView(onHideDiagnostics: { settings.diagnosticsUnlocked = false })
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
                    .labelStyle(.tintedIcon(.teal))
            }
            .accessibilityIdentifier("settings.diagnostics")
        } footer: {
            Text("Shows this launch's iCloud sync activity, for troubleshooting and bug reports.")
        }
    }
}
```

`AboutSettingsSection`'s `onRevealDiagnostics` flips `diagnosticsUnlocked` in *its own* `AppSettings`
instance; this view's separate instance reads the same `UserDefaults`, and its `@State` re-read is
triggered by the toast assignment re-rendering the body. If the section does not appear immediately
in a manual check, have the callback also set a local `@State private var diagnosticsRevealed = false`
and gate on `settings.diagnosticsUnlocked || diagnosticsRevealed`.

- [ ] **Step 2: Add the Mac pane**

In `Yana/Reader/Mac/WindowID.swift`, extend `SettingsPane`:

```swift
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, feeds, tags, integrations, ai, about, diagnostics
```

and add to both switches:

```swift
        case .diagnostics: "Diagnostics"
```

```swift
        case .diagnostics: "stethoscope"
```

- [ ] **Step 3: Gate and render the pane in the Mac Settings window**

In `Yana/Reader/Mac/MacSettingsWindow.swift`:

```swift
struct MacSettingsWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPane? = .general
    @State private var settings = AppSettings()

    /// Diagnostics is hidden until the version row in About is tapped five times, so the sidebar is
    /// built from this rather than `allCases`.
    private var visiblePanes: [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .diagnostics || settings.diagnosticsUnlocked }
    }
```

Replace `ForEach(SettingsPane.allCases)` with `ForEach(visiblePanes)`, and add the detail branch:

```swift
        case .diagnostics:
            SyncLogView(onHideDiagnostics: {
                settings.diagnosticsUnlocked = false
                selection = .about
            })
```

Also pass the reveal callback through the `.about` branch so the pane appears after the gesture:

```swift
        case .about:
            Form {
                AboutSettingsSection(
                    onRestartOnboarding: {
                        openWindow(id: WindowID.welcome, value: true)
                        dismiss()
                    },
                    onRevealDiagnostics: { selection = .diagnostics }
                )
            }
```

- [ ] **Step 4: Build both destinations and run the suite**

```bash
xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

```bash
xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac-synclog build
```

Expected: tests pass, both builds succeed.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Reader/Mac/WindowID.swift Yana/Reader/Mac/MacSettingsWindow.swift
git commit -m "Surface the diagnostics log in iOS and Mac settings"
```

---

### Task 10: Localization and documentation

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings`, `CLAUDE.md`

**Interfaces:**
- Consumes: every user-facing string added in Tasks 7–9.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Collect the new strings**

Grep the new and modified view files for user-facing literals:

```bash
grep -rn '"[A-Z]' Yana/Views/Config/Settings/SyncLogView.swift Yana/Views/Config/Settings/SyncLogHeaderView.swift Yana/Views/Config/Settings/AboutSettingsSection.swift Yana/Views/Config/SettingsScreenView.swift Yana/Reader/Mac/WindowID.swift
```

Expected set (verify against the actual code — this list must match exactly what is in the views):

| English | German |
| --- | --- |
| Diagnostics | Diagnose |
| Sync Status | Synchronisierungsstatus |
| Version | Version |
| Filter | Filter |
| Level | Stufe |
| Source | Quelle |
| All | Alle |
| App | App |
| System | System |
| No Entries | Keine Einträge |
| Nothing matches the current filter. The log covers this app launch only — the system portion shows only entries the unified log kept, which is often nothing. | Nichts entspricht dem aktuellen Filter. Das Protokoll umfasst nur den aktuellen App-Start — der Systemteil zeigt nur Einträge, die das Systemprotokoll behalten hat, was oft keine sind. |
| %lld entries | %lld Einträge |
| Copy Log | Protokoll kopieren |
| Log copied | Protokoll kopiert |
| Yana Sync Log | Yana-Synchronisierungsprotokoll |
| Hide Diagnostics | Diagnose ausblenden |
| Hiding removes this screen from Settings. Tap the version row in About five times to bring it back. | Beim Ausblenden verschwindet dieser Bereich aus den Einstellungen. Fünfmal auf die Version unter „Über“ tippen, um ihn wieder einzublenden. |
| Diagnostics enabled | Diagnose aktiviert |
| Shows this launch's iCloud sync activity, for troubleshooting and bug reports. | Zeigt die iCloud-Synchronisierung des aktuellen App-Starts — für Fehlersuche und Fehlerberichte. |
| iCloud Account | iCloud-Account |
| Container | Container |
| Environment | Umgebung |
| Library | Bibliothek |
| Last Import | Letzter Import |
| Last Export | Letzter Export |
| Last Error | Letzter Fehler |

- [ ] **Step 2: Add each string to the catalog**

`Yana/Resources/Localizable.xcstrings` is JSON (`"version": "1.1"`, `"sourceLanguage": "en"`). Add
one entry per English key under `"strings"`, in the existing shape:

```json
    "Hide Diagnostics" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Diagnose ausblenden"
          }
        }
      }
    },
```

Keys must stay sorted the way the file already orders them, and the file must remain valid JSON.
Verify:

```bash
python3 -c "import json; d=json.load(open('Yana/Resources/Localizable.xcstrings')); print(len(d['strings']), 'strings OK')"
```

- [ ] **Step 3: Check that every new string is translated**

```bash
python3 - <<'PY'
import json
d = json.load(open('Yana/Resources/Localizable.xcstrings'))
missing = [k for k, v in d['strings'].items()
           if v.get('localizations', {}).get('de', {}).get('stringUnit', {}).get('state') != 'translated'
           and not v.get('shouldTranslate') is False]
print("untranslated:", missing)
PY
```

Expected: the list contains no string added in this plan. (Pre-existing entries that were already
untranslated are out of scope.)

- [ ] **Step 4: Update `CLAUDE.md`**

In the **Services** bullet under *Architecture*, add the new units to the existing prose — after the
`LegacyCloudKitCleanup` sentence:

```markdown
  **Diagnostics:** `SyncLog` (`Yana/Services/SyncLog.swift`) is a nonisolated, lock-protected
  in-memory ring buffer (2000 entries, current launch only — no file persistence) that every sync
  path writes to; each entry is mirrored to `Logger` with `privacy: .public`.
  **`CloudKitSyncMonitor`** (`Yana/Services/CloudKitSyncMonitor.swift`) observes
  `NSPersistentCloudKitContainer.eventChangedNotification` and re-logs the **full** `NSError` tree
  (userInfo keys, `CKPartialErrors`, `NSUnderlyingError`, recursively) — necessary because
  CoreData's own `com.apple.coredata` lines redact the useful values to `<private>`. **Ordering is
  load-bearing:** `start()` runs as the first statement inside the `AppContainer.shared` closure,
  before any `ModelContainer` exists, because setup events fire during `ModelContainer.init`.
  `SystemLogReader` adds a best-effort `OSLogStore(scope: .currentProcessIdentifier)` read of
  `com.apple.coredata` (persisted entries only — often empty, and a blackout on a locally built
  Catalyst run), and `SyncDiagnostics` builds the status header (iCloud account status, container,
  CloudKit environment from the build configuration, row counts, last import/export, last error).
```

Then, in the **Views** bullet, note the surface:

```markdown
  A **Diagnostics** section (iOS) and `SettingsPane.diagnostics` (Mac) present `SyncLogView` — the
  in-app sync log with a pinned status header, level/source/text filters, copy, and a `.txt`
  `ShareLink`. It ships in release builds but stays hidden until the **About → Version** row is
  tapped five times (`DiagnosticsReveal`, `AppSettings.diagnosticsUnlocked` — device-local, never
  synced).
```

- [ ] **Step 5: Full verification**

```bash
xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

```bash
xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/yana-mac-synclog build
```

Expected: all tests pass; both builds succeed. Paste the actual result lines into the task report —
do not claim success without them.

- [ ] **Step 6: Commit**

```bash
git add Yana/Resources/Localizable.xcstrings CLAUDE.md
git commit -m "Localize the diagnostics log and document it"
```

---

## Manual verification (after Task 10)

The automated suite cannot exercise the CloudKit path — do this by hand on a real signed-in device
or the Mac build, run from a real Terminal (Catalyst signing does not work from an automation shell):

1. Launch the app, open Settings → About, tap **Version** five times. The Diagnostics entry appears.
2. Open Diagnostics. The status header should show your iCloud account status, the
   `iCloud.de.fa-krug.Yana` container, and the environment. Confirm the environment matches the
   build you are running (Xcode build → Development; TestFlight → Production).
3. Pull to update a feed, then look for `setup`/`export` lines under the `CloudKit` category. A
   failing export prints `export FAILED` followed by the indented error tree — that tree is the
   answer to why sync is broken.
4. Copy the log and read it. **This is the point of the whole feature** — the sync fix itself is a
   separate piece of work informed by what this shows.
