import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Searchable flat list of feeds with tag chips, last-fetched time, error badge, enable state,
/// per-feed update, and article count. Add / delete (with confirmation); "Update all".
struct FeedsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @State private var isUpdating = false
    @State private var isImporting = false
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var importMessage: String?
    @State private var feedToDelete: Feed?
    @State private var searchText = ""

    private var filteredFeeds: [Feed] {
        NameSearch.filter(feeds, query: searchText, name: \.name)
    }

    var body: some View {
        ManagedList(
            items: filteredFeeds,
            searchText: $searchText,
            searchPrompt: "Search feeds",
            emptyTitle: "No Feeds",
            emptyIcon: "list.bullet.rectangle",
            emptyDescription: "Tap + to add your first feed.",
            onDelete: { offsets in
                // Resolve immediately so stale indices can't delete the wrong feed
                guard let feed = offsets.map({ filteredFeeds[$0] }).first else { return }
                feedToDelete = feed
            },
            leadingActions: { feed in
                Button {
                    Task { await updateOne(feed) }
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
                .disabled(isUpdating)
                Button {
                    Task { await forceReloadOne(feed) }
                } label: {
                    Label("Force reload", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .tint(.orange)
                .disabled(isUpdating)
            }
        ) { feed in
            NavigationLink {
                FeedEditorView(feed: feed)
            } label: {
                row(feed)
            }
        }
        .navigationTitle("Feeds")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    FeedEditorView(feed: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isUpdating {
                    ProgressView()
                } else {
                    Button("Update All") { Task { await updateAll() } }
                        .disabled(feeds.isEmpty)
                }
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
        .confirmationDialog(
            String(localized: "Delete Feed?"),
            isPresented: Binding(get: { feedToDelete != nil }, set: { if !$0 { feedToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let feed = feedToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    modelContext.delete(feed)
                    try? modelContext.save()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let feed = feedToDelete {
                Text(
                    String(localized: "Delete \u{201C}\(feed.name)\u{201D}? Its \(feed.articles.count) articles will be removed.")
                )
            }
        }
    }

    private func row(_ feed: Feed) -> some View {
        let lastError = feed.lastError
        return HStack(spacing: 12) {
            FeedLogoView(hash: feed.logoHash)
            VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.name).font(.headline)
                if !feed.enabled {
                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                }
                if lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(String(localized: "Update error"))
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
            if let error = lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !feed.tags.isEmpty {
                Text(feed.tags.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            }
        }
    }

    private func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        let count = await AggregationService(context: modelContext).updateAll()
        if count == 0 {
            importMessage = String(localized: "No new articles.")
        } else {
            importMessage = String(localized: "Added \(count) new \(count == 1 ? "article" : "articles").")
        }
    }

    private func updateOne(_ feed: Feed) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        let count = await AggregationService(context: modelContext).update(feed: feed)
        if count == 0 {
            importMessage = String(localized: "No new articles.")
        } else {
            importMessage = String(localized: "Added \(count) new \(count == 1 ? "article" : "articles") from \u{201C}\(feed.name)\u{201D}.")
        }
    }

    private func forceReloadOne(_ feed: Feed) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        let count = await AggregationService(context: modelContext).forceReload(feed: feed)
        if count == 0 {
            importMessage = String(localized: "Reloaded \u{201C}\(feed.name)\u{201D}.")
        } else {
            importMessage = String(localized: "Added \(count) new \(count == 1 ? "article" : "articles") from \u{201C}\(feed.name)\u{201D}.")
        }
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
