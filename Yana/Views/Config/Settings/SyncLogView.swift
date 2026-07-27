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
struct SyncLogView: View {
    /// Called when the user chooses to hide diagnostics again, so the presenting settings surface can
    /// drop its Diagnostics entry (each settings screen owns its own `AppSettings` instance, so the
    /// flag change has to be handed back rather than observed).
    var onHideDiagnostics: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    @State private var entries: [SyncLog.Entry] = []
    @State private var filter = SyncLogFilter()
    /// The filtered entries actually shown/copied/shared. Held as state and recomputed only when
    /// `entries` or `filter` actually change (in `reloadEntries()` and the `filter` `onChange`),
    /// rather than as a computed property re-evaluated on every body pass — `SyncLogFilter.apply`
    /// walks the whole buffer and does up to two ICU case-insensitive substring checks per entry, so
    /// recomputing it five times per render (once per read site) at the 2000-entry cap would be
    /// thousands of ICU comparisons a second during exactly the export burst this screen exists to
    /// observe.
    @State private var visibleEntries: [SyncLog.Entry] = []
    /// `SyncLog.exportText(visibleEntries)` cached alongside `visibleEntries` for the same reason —
    /// it joins the whole filtered set into one string, and both the Copy button and `ShareLink`
    /// would otherwise rebuild it on every render.
    @State private var exportText: String = ""
    @State private var diagnostics: SyncDiagnostics?
    @State private var isHeaderExpanded = true
    @State private var toast: ToastMessage?
    /// Scroll to the newest entry once, on the first real render that has rows. Not on every 1 s
    /// tick — that would yank the list out from under you while reading.
    @State private var hasScrolledToNewest = false
    /// Counts entry-poll ticks so diagnostics (which cost a `CKContainer.accountStatus()` XPC round
    /// trip plus four SQLite `fetchCount`s) refresh on a much slower cadence than the log itself —
    /// see `diagnosticsRefreshEveryNTicks`.
    @State private var tickCount = 0

    /// Diagnostics refresh every Nth entry tick (entries poll at 1 s, so 15 → ~15 s). Account status,
    /// container, and environment are effectively constant for the session and the counts drift
    /// slowly, so there is nothing to gain from refreshing them at 1 Hz — especially while the
    /// header `DisclosureGroup` may not even be expanded.
    private static let diagnosticsRefreshEveryNTicks = 15

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
                .accessibilityIdentifier("settings.diagnostics.copy")
                .disabled(visibleEntries.isEmpty)
            }
            ToolbarItem {
                ShareLink(
                    item: SyncLogDocument(text: exportText),
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
        // do nothing. Gating on `!hasScrolledToNewest` keeps this a one-time park at the bottom.
        .onChange(of: entries.count) {
            guard !hasScrolledToNewest, let last = visibleEntries.last else { return }
            proxy.scrollTo(last.id, anchor: .bottom)
            hasScrolledToNewest = true
        }
        .onChange(of: filter) {
            updateVisibleEntries()
        }
        .task {
            await reloadEntries()
            await refreshDiagnostics()
            // Poll instead of observing: see the type comment.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                await reloadEntries()
                // Backstop for the `onChange` above: if the very first load already had rows and the
                // change somehow wasn't observed (e.g. `entries.count` was unchanged because the
                // first batch was empty and stayed empty until now), catch up here too.
                if !hasScrolledToNewest, let last = visibleEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                    hasScrolledToNewest = true
                }
                tickCount += 1
                if tickCount % Self.diagnosticsRefreshEveryNTicks == 0 {
                    await refreshDiagnostics()
                }
            }
        }
        .accessibilityIdentifier("settings.diagnostics.log")
    }

    private func reloadEntries() async {
        let buffered = SyncLog.shared.snapshot()
        let system = await SystemLogReader.fetch(since: SystemLogReader.logWindowStart)
        entries = (buffered + system).sorted { lhs, rhs in
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

    private func refreshDiagnostics() async {
        diagnostics = await SyncDiagnostics.make(context: modelContext)
    }

    private func updateVisibleEntries() {
        let filtered = filter.apply(to: entries)
        visibleEntries = filtered
        exportText = SyncLog.exportText(filtered)
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
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { document in
            Data(document.text.utf8)
        }
        .suggestedFileName("yana-sync-log.txt")
    }
}
