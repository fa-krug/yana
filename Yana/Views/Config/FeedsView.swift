import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Flat list of feeds with tag chips, last-fetched time, error badge, enable state,
/// per-feed update, and article count. Add / delete; "Update all".
struct FeedsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @State private var isUpdating = false
    @State private var isImporting = false
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var importMessage: String?

    var body: some View {
        List {
            ForEach(feeds) { feed in
                NavigationLink {
                    FeedEditorView(feed: feed)
                } label: {
                    row(feed)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(feed)
                        try? modelContext.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await updateOne(feed) }
                    } label: {
                        Label("Update", systemImage: "arrow.clockwise")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Feeds")
        .overlay {
            if feeds.isEmpty {
                ContentUnavailableView("No Feeds", systemImage: "list.bullet.rectangle",
                                       description: Text("Tap + to add your first feed."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    FeedEditorView(feed: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Update All") { Task { await updateAll() } }
                    .disabled(isUpdating || feeds.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { exportOPML() } label: { Label("Export OPML", systemImage: "square.and.arrow.up") }
                    Button { isImporting = true } label: { Label("Import OPML", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $isExporting) {
            if let url = exportURL { ShareSheet(activityItems: [url]) }
        }
        .alert("Feeds", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func row(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.name).font(.headline)
                if !feed.enabled {
                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                }
                if feed.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            HStack(spacing: 6) {
                Text(feed.type.displayName)
                Text("· \(feed.articles.count) articles")
                if let fetched = feed.lastFetchedAt {
                    Text("· \(fetched, style: .relative) ago")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !feed.tags.isEmpty {
                Text(feed.tags.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        await AggregationService(context: modelContext).updateAll()
    }

    private func updateOne(_ feed: Feed) async {
        await AggregationService(context: modelContext).update(feed: feed)
    }

    private func exportOPML() {
        let xml = FeedPortability.exportOPML(context: modelContext)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Yana-Feeds.opml")
        do {
            try xml.data(using: .utf8)?.write(to: url)
            exportURL = url
            isExporting = true
        } catch {
            importMessage = String(localized: "Export failed.")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
            importMessage = String(localized: "Could not read the file.")
            return
        }
        let r = FeedPortability.importOPML(xml, context: modelContext)
        importMessage = String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped).")
    }
}
