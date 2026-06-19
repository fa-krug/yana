import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Searchable flat list of feeds with tag chips, last-fetched time, error badge, enable state,
/// per-feed update, and article count. Add / delete (with confirmation); "Update all".
struct FeedsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @State private var isImporting = false
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var toast: ToastMessage?
    @State private var feedToDelete: Feed?
    @State private var searchText = ""
    @State private var settings = AppSettings()
    @State private var showingCreateFeed = false
    @State private var articleCounts: [PersistentIdentifier: Int] = [:]

    private func refreshArticleCounts() {
        var counts: [PersistentIdentifier: Int] = [:]
        for feed in feeds {
            let id = feed.persistentModelID
            let descriptor = FetchDescriptor<Article>(
                predicate: #Predicate { $0.feed?.persistentModelID == id }
            )
            counts[id] = (try? modelContext.fetchCount(descriptor)) ?? 0
        }
        articleCounts = counts
    }

    /// Shared, app-lifetime flag so the spinner survives leaving and returning to this screen
    /// while a detached update Task keeps running in the background.
    private var isUpdating: Bool { UpdateActivity.shared.isUpdating }

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
                    updateOne(feed)
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
                .disabled(!settings.isSourceEnabled(feed.type))
                Button {
                    forceReloadOne(feed)
                } label: {
                    Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .tint(.orange)
                .disabled(!settings.isSourceEnabled(feed.type))
            }
        ) { feed in
            NavigationLink {
                FeedEditorView(feed: feed)
            } label: {
                row(feed)
            }
        }
        .navigationTitle("Feeds")
        .onAppear { refreshArticleCounts() }
        .onChange(of: feeds) { _, _ in refreshArticleCounts() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreateFeed = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isUpdating {
                    // While any update runs, the button becomes a tappable spinner that stops it.
                    Button { UpdateActivity.shared.cancel() } label: {
                        ProgressView()
                    }
                    .accessibilityLabel(Text("Stop updating"))
                } else {
                    Button { updateAll() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(feeds.isEmpty)
                    .accessibilityLabel(Text("Update all"))
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
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack { FeedEditorView(feed: nil) }
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
        .toast($toast)
        .confirmationDialog(
            String(localized: "Delete Feed?"),
            isPresented: Binding(get: { feedToDelete != nil }, set: { if !$0 { feedToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let feed = feedToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    modelContext.delete(feed)
                    try? modelContext.save()
                    Haptics.notify(.success)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let feed = feedToDelete {
                Text(
                    String(localized: "Delete \u{201C}\(feed.name)\u{201D}? Its \(feed.articles.count) articles will be permanently deleted.")
                )
            }
        }
    }

    /// A small capsule chip used for at-a-glance feed status (disabled, source off).
    private func badge(_ text: Text, tint: Color) -> some View {
        text
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }

    private func row(_ feed: Feed) -> some View {
        let lastError = feed.lastError
        return HStack(spacing: 12) {
            FeedLogoView(hash: feed.logoHash)
            VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.name).font(.headline)
                if !feed.enabled {
                    badge(Text("Disabled"), tint: .secondary)
                }
                if !settings.isSourceEnabled(feed.type) {
                    badge(Text("\(feed.type.displayName) off"), tint: .orange)
                }
                if lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(String(localized: "Update error"))
                }
            }
            HStack(spacing: 6) {
                Text("\(articleCounts[feed.persistentModelID] ?? 0) articles")
                if let fetched = feed.lastFetchedAt {
                    Text(verbatim: "· \(RelativeTime.compact(since: fetched))")
                        .monospacedDigit()
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
                HStack(spacing: 4) {
                    ForEach(feed.tags.sorted { $0.name < $1.name }, id: \.name) { tag in
                        TagChip(name: tag.name, colorHex: tag.colorHex)
                    }
                }
            }
            }
        }
    }

    private func updateAll() {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).updateAll()
            guard !Task.isCancelled else { return }
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: nil))
        }
    }

    private func updateOne(_ feed: Feed) {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).update(feed: feed)
            guard !Task.isCancelled else { return }
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
        }
    }

    private func forceReloadOne(_ feed: Feed) {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).forceReload(feed: feed)
            guard !Task.isCancelled else { return }
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
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
            toast = ToastMessage(text: String(localized: "Export failed."), style: .error)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
            toast = ToastMessage(text: String(localized: "Could not read the file."), style: .error)
            return
        }
        let r = FeedPortability.importOPML(xml, context: modelContext)
        toast = ToastMessage(text: String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped)."))
    }
}
