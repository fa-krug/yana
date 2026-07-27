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
