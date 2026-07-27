import CoreTransferable
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The diagnostics log screen: a pinned status header, a filter bar, and the merged entry list
/// (`SyncLog`'s own buffer plus whatever `SystemLogReader` can see of CoreData's mirroring lines).
///
/// Refreshes on a 1 s tick while visible rather than observing `SyncLog`, because a CloudKit export
/// burst produces hundreds of entries in a second and per-entry SwiftUI invalidation would make the
/// screen unusable exactly when it matters.
///
/// The tick is deliberately cheap: it reads `SyncLog.snapshot()` and returns immediately unless the
/// buffer actually changed. Merging, sorting, filtering, the system-log read, and rendering the
/// export string are all off the tick — an unbounded main-actor cost repeated every second on a
/// screen whose whole job is to stay responsive during a sync storm is the one thing this screen
/// cannot afford.
struct SyncLogView: View {
    /// Called when the user chooses to hide diagnostics again, so the presenting settings surface can
    /// drop its Diagnostics entry (each settings screen owns its own `AppSettings` instance, so the
    /// flag change has to be handed back rather than observed).
    var onHideDiagnostics: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    /// `SyncLog`'s buffer as of the last tick that saw a change. Kept separately from `entries` so a
    /// tick can compare cheaply and bail.
    @State private var bufferedEntries: [SyncLog.Entry] = []
    /// The unified-log supplement. Fetched when the screen opens and on an explicit refresh — **not**
    /// per tick: `SystemLogReader.fetch` re-enumerates the log from boot every time, a cost that grows
    /// with uptime and with Yana's own os_log volume (which this feature increased). Fetching once
    /// also stabilises row identity: system `sequence` renumbers from 0 on every fetch, so re-fetching
    /// churned every system row's `id` and made `ForEach` rebuild it, losing text selection.
    @State private var systemEntries: [SyncLog.Entry] = []
    @State private var entries: [SyncLog.Entry] = []
    @State private var filter = SyncLogFilter()
    /// The filtered entries actually shown/copied/shared. Held as state and recomputed only when the
    /// merged entries or the filter actually change, rather than as a computed property re-evaluated
    /// on every body pass — `SyncLogFilter.apply` walks the whole buffer and does up to two ICU
    /// case-insensitive substring checks per entry.
    @State private var visibleEntries: [SyncLog.Entry] = []
    @State private var diagnostics: SyncDiagnostics?
    @State private var isHeaderExpanded = true
    @State private var toast: ToastMessage?
    /// Scroll to the newest entry once, on the first real render that has rows. Not on every 1 s
    /// tick — that would yank the list out from under you while reading. Owned exclusively by the
    /// `onChange(of: entries.count)` hook below; nothing else may set it.
    @State private var hasScrolledToNewest = false
    /// Counts entry-poll ticks so diagnostics (which cost a `CKContainer.accountStatus()` XPC round
    /// trip plus four SQLite `fetchCount`s) refresh on a much slower cadence than the log itself —
    /// see `diagnosticsRefreshEveryNTicks`.
    @State private var tickCount = 0

    /// Diagnostics refresh every Nth entry tick (entries poll at 1 s, so 15 → ~15 s). Account status,
    /// container, and environment are effectively constant for the session and the counts drift
    /// slowly, so there is nothing to gain from refreshing them at 1 Hz — especially while the
    /// header `DisclosureGroup` may not even be expanded. The toolbar Refresh button covers the case
    /// where you *have* just changed something (signed into iCloud, say) and want to see it now.
    private static let diagnosticsRefreshEveryNTicks = 15

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy: proxy)
        }
    }

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        titled(logList)
        .toast($toast)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshEverything() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text("Refresh"))
                .accessibilityIdentifier("settings.diagnostics.refresh")
            }
            ToolbarItem {
                Button {
                    UIPasteboard.general.string = exportPayload()
                    toast = ToastMessage(text: String(localized: "Log copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(Text("Copy Log"))
                .accessibilityIdentifier("settings.diagnostics.copy")
                .disabled(visibleEntries.isEmpty)
            }
            ToolbarItem {
                // `SyncLogDocument` holds a *closure*, not the rendered string: `ShareLink`'s item is
                // rebuilt on every render pass, and rendering the export eagerly meant one
                // ISO-8601 format call per entry (up to 2000) per render, for a string nobody had
                // asked for. The closure runs only when the user actually shares.
                ShareLink(
                    item: SyncLogDocument(makeText: exportPayloadProvider()),
                    preview: SharePreview("Yana Sync Log")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.diagnostics.share")
                .disabled(visibleEntries.isEmpty)
            }
        }
        // Scrolling on `entries.count` (a real state mutation that has already updated
        // `visibleEntries` by the time this fires) rather than immediately after the first
        // `reload()` call: assigning `entries` only *schedules* a re-render, so a `scrollTo` issued
        // synchronously right after would target rows that SwiftUI has not laid out yet and silently
        // do nothing. This hook is the *only* place `hasScrolledToNewest` is set — the poll loop used
        // to set it too, from a `scrollTo` issued before the target row was registered, which parked
        // the list at the top whenever the screen opened on an empty buffer and rows arrived later.
        .onChange(of: entries.count) {
            guard !hasScrolledToNewest, let last = visibleEntries.last else { return }
            proxy.scrollTo(last.id, anchor: .bottom)
            hasScrolledToNewest = true
        }
        .onChange(of: filter) {
            updateVisibleEntries()
        }
        .task {
            // Puts the account status into the *entry stream* (not only the header), once per launch.
            // Kept off the launch path on purpose — see `CloudKitSyncMonitor.logAccountStatusOnce`.
            await CloudKitSyncMonitor.shared.logAccountStatusOnce()
            reloadBufferedEntries()
            await refreshSystemEntries()
            await refreshDiagnostics()
            // Poll instead of observing: see the type comment.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                reloadBufferedEntries()
                tickCount += 1
                if tickCount % Self.diagnosticsRefreshEveryNTicks == 0 {
                    await refreshDiagnostics()
                }
            }
        }
        .accessibilityIdentifier("settings.diagnostics.log")
    }

    private var logList: some View {
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
                        Text(Self.levelLabel(level)).tag(SyncLog.Level?.some(level))
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
                    }
                }
            } header: {
                Text("\(visibleEntries.count) entries")
            } footer: {
                // Sharing is an informed choice: the log records feed and article identities, and a
                // CloudKit error can quote a record's fields.
                Text("Copying or sharing the log may include article titles and links, so read it before sending it to anyone.")
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
    }

    /// `navigationTitle` on iOS only. On Mac Catalyst this view is a *pane* of the Settings window,
    /// and no other `SettingsPane` sets a title — setting one here retitles the window.
    @ViewBuilder
    private func titled(_ content: some View) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        content.navigationTitle("Diagnostics")
        #endif
    }

    // MARK: - Loading

    /// Cheap per-tick read. Returns without touching any state unless the buffer actually changed —
    /// which is the common case, since the log is idle most of the time.
    private func reloadBufferedEntries() {
        let buffered = SyncLog.shared.snapshot()
        // Sequences are monotonic and eviction only ever drops a prefix, so count + first id + last id
        // identify the buffer's contents exactly. Comparing counts alone would miss the case where a
        // full buffer evicts as many entries as it gains.
        let unchanged = buffered.count == bufferedEntries.count
            && buffered.first?.id == bufferedEntries.first?.id
            && buffered.last?.id == bufferedEntries.last?.id
        guard !unchanged else { return }

        bufferedEntries = buffered
        mergeEntries()
    }

    private func refreshSystemEntries() async {
        systemEntries = await SystemLogReader.fetch(since: SystemLogReader.logWindowStart)
        mergeEntries()
    }

    private func refreshDiagnostics() async {
        diagnostics = await SyncDiagnostics.make(context: modelContext)
    }

    /// Force everything, for the toolbar Refresh button: the buffer, the unified-log supplement, and
    /// the status header.
    private func refreshEverything() async {
        bufferedEntries = SyncLog.shared.snapshot()
        await refreshSystemEntries()
        await refreshDiagnostics()
    }

    private func mergeEntries() {
        entries = (bufferedEntries + systemEntries).sorted { lhs, rhs in
            // Not just `date <`: two entries can share a timestamp (system-clock resolution, or an
            // app entry and a system entry logged in the same instant), and an unstable sort would
            // let them swap order between polls, making rows visibly jump. Break ties by source then
            // by each source's own monotonic sequence.
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
            return lhs.sequence < rhs.sequence
        }
        updateVisibleEntries()
    }

    private func updateVisibleEntries() {
        visibleEntries = filter.apply(to: entries)
    }

    // MARK: - Export

    /// Header block + one line per entry. Built on demand (Copy, or an actual share), never kept in
    /// state: at the 2000-entry cap it is ~2000 `ISO8601DateFormatter` calls.
    private func exportPayload() -> String {
        Self.exportPayload(entries: visibleEntries, header: diagnostics?.exportHeader())
    }

    /// A `@Sendable` snapshot of the current export inputs, so `ShareLink` can hold something cheap
    /// and render lazily.
    private func exportPayloadProvider() -> @Sendable () -> String {
        // Captures the values, renders nothing: this runs on every render pass, so even
        // `exportHeader()` is deferred into the closure.
        let entries = visibleEntries
        let diagnostics = diagnostics
        return { Self.exportPayload(entries: entries, header: diagnostics?.exportHeader()) }
    }

    /// The status header is prepended so an exported log is self-describing. Without it a log pasted
    /// into an issue carried no account status, container, CloudKit environment, app version, OS, or
    /// row counts — and environment mismatch and account state are the two most likely causes of the
    /// failure being reported.
    nonisolated static func exportPayload(entries: [SyncLog.Entry], header: String?) -> String {
        let body = SyncLog.exportText(entries)
        guard let header else { return body }
        return body.isEmpty ? header : "\(header)\n\n\(body)"
    }

    private static func levelLabel(_ level: SyncLog.Level) -> LocalizedStringKey {
        switch level {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .error: "Error"
        }
    }
}

/// Exports the log as a `.txt` attachment, so the share sheet offers Mail/Files rather than pasting
/// thousands of lines of plain text into a message body.
struct SyncLogDocument: Transferable {
    /// Rendered lazily — see the `ShareLink` call site.
    let makeText: @Sendable () -> String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { document in
            Data(document.makeText().utf8)
        }
        .suggestedFileName("yana-sync-log.txt")
    }
}
