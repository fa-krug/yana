import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Searchable flat list of feeds with tag chips, last-fetched time, error badge, enable state,
/// per-feed update, and article count. Add / delete (with confirmation); "Update all".
///
/// Owns the state a user can be mid-interaction with — search text, the create/export sheets, the
/// delete confirmation, an in-flight OPML import, the toast — plus every modifier that
/// *presents* something (`.sheet`, `.fileImporter`, `.alert`, `.toast`). `FeedsListContent` owns
/// the `@Query` and everything that only needs to *display* feed data; it's re-identified by
/// `.id()` on a CloudKit remote-change bump (see `LibraryRevision`), since `@Query` never sees
/// `.NSPersistentStoreRemoteChange` on its own. Keeping the presentation modifiers on this stable
/// outer view means a merge landing while, say, the create-feed sheet is open never dismisses it —
/// only a view's presentation host, not the thing it presents, would be affected by the child's
/// identity reset.
struct FeedsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isImporting = false
    @State private var isImportingOPML = false
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var toast: ToastMessage?
    @State private var feedToDelete: Feed?
    @State private var searchText = ""
    @State private var showingCreateFeed = false

    var body: some View {
        FeedsListContent(
            searchText: $searchText,
            feedToDelete: $feedToDelete,
            showingCreateFeed: $showingCreateFeed,
            isImporting: $isImporting,
            isImportingOPML: $isImportingOPML,
            toast: $toast,
            onExportOPML: exportOPML
        )
        // `.searchable()` lives here, on the stable parent, not inside the `.id()`'d
        // `FeedsListContent` — `.id()` tears down and recreates everything under it, including the
        // search field's backing controller. The `searchText` *value* would survive (it's a
        // `@Binding` into this view's own `@State`), but first-responder status/cursor/keyboard
        // would not, silently kicking focus out of the field mid-typing. See `ManagedList`'s doc
        // comment.
        .searchable(text: $searchText, placement: ManagedListSearch.placement, prompt: "Search feeds")
        .navigationTitle("Feeds")
        // Creating a feed is a sheet on both platforms, like Add Tag — not a separate Mac window.
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                FeedEditorView(feed: nil) { newFeed in
                    // Fetch the just-added feed right away, unless it was created disabled.
                    guard newFeed.enabled else { return }
                    UpdateActivity.shared.restart {
                        let count = await AggregationService(context: modelContext).update(feed: newFeed)
                        guard !Task.isCancelled else { return }
                        toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: newFeed.name))
                    }
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
        .toast($toast)
        .alert(
            String(localized: "Delete Feed?"),
            isPresented: Binding(get: { feedToDelete != nil }, set: { if !$0 { feedToDelete = nil } })
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
                    String(localized: "Delete \u{201C}\(feed.name)\u{201D}? Its \((feed.articles ?? []).count) articles will be permanently deleted.")
                )
            }
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
        isImportingOPML = true
        // Let SwiftUI paint the overlay before the synchronous parse blocks the main actor.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            defer { isImportingOPML = false }
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
}

/// The `@Query`-owning half of `FeedsView`; see that type's doc comment for why it's split out.
/// Everything here only *displays* feed data or fires a background update/reload — nothing here
/// presents a sheet/alert/fileImporter, so a `.id()` reset (recreating this whole subview) never
/// dismisses anything the user has open.
private struct FeedsListContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @Binding var searchText: String
    @Binding var feedToDelete: Feed?
    @Binding var showingCreateFeed: Bool
    @Binding var isImporting: Bool
    @Binding var isImportingOPML: Bool
    @Binding var toast: ToastMessage?
    let onExportOPML: () -> Void
    @State private var settings = AppSettings()
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
            // Editing pushes in place on both platforms, like the Tags pane — on the Mac that is
            // inside the Settings window's `NavigationStack`, so a feed no longer takes over a
            // separate window.
            NavigationLink {
                FeedEditorView(feed: feed)
            } label: {
                row(feed)
            }
        }
        .overlay {
            if isImportingOPML {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Importing feeds…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(Motion.resolve(CrossFade.transition, reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.resolve(CrossFade.animation, reduceMotion: reduceMotion), value: isImportingOPML)
        .onAppear { refreshArticleCounts() }
        .onChange(of: feeds) { _, _ in refreshArticleCounts() }
        .toolbar { feedsToolbar }
    }

    @ToolbarContentBuilder private var feedsToolbar: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        // On the Mac every action goes in ONE `ControlGroup` — the system's joined toolbar group,
        // matching the reader window's toolbar (see `MacRootView.toolbar` for why it is a
        // `ControlGroup` hosted directly by a `ToolbarItem` and not a `ToolbarItemGroup`). The
        // update segment cross-fades to a spinner while a run is in flight, which keeps the item
        // set constant — that is what Catalyst needs to avoid re-validation flicker; tapping it
        // then cancels the run.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    if isUpdating { UpdateActivity.shared.cancel() } else { updateAll() }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.clockwise").opacity(isUpdating ? 0 : 1)
                        ProgressView().controlSize(.small).opacity(isUpdating ? 1 : 0)
                    }
                    .macToolbarIcon()
                }
                .disabled(!isUpdating && feeds.isEmpty)
                .help(isUpdating ? Text("Stop updating") : Text("Update all"))
                .accessibilityLabel(isUpdating ? Text("Stop updating") : Text("Update all"))

                Button {
                    showingCreateFeed = true
                } label: {
                    Label("Add Feed", systemImage: "plus").macToolbarIcon()
                }
                .help(Text("Add Feed"))
            }
        }
        // The overflow menu is its own item, matching the reader window: a pull-down is not a peer
        // action, so it never becomes a segment of the group.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { onExportOPML() } label: { Label("Export OPML", systemImage: "square.and.arrow.up") }
                Button { isImporting = true } label: { Label("Import OPML", systemImage: "square.and.arrow.down") }
            } label: {
                Label("More", systemImage: "ellipsis").macToolbarIcon()
            }
            // A pull-down chevron beside the ellipsis is redundant — the glyph already reads as
            // "more". `.menuIndicator(.hidden)` is the standard way to drop it.
            .menuIndicator(.hidden)
            .help(Text("More"))
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingCreateFeed = true } label: { Image(systemName: "plus") }
        }
        ToolbarItem(placement: .topBarLeading) {
            if isUpdating {
                // While any update runs, the button becomes a tappable spinner that stops it.
                Button { UpdateActivity.shared.cancel() } label: { ProgressView() }
                    .accessibilityLabel(Text("Stop updating"))
            } else {
                Button { updateAll() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(feeds.isEmpty)
                    .accessibilityLabel(Text("Update all"))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { onExportOPML() } label: { Label("Export OPML", systemImage: "square.and.arrow.up") }
                Button { isImporting = true } label: { Label("Import OPML", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        #endif
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
            if !(feed.tags ?? []).isEmpty {
                HStack(spacing: 4) {
                    ForEach((feed.tags ?? []).sorted { $0.name < $1.name }, id: \.name) { tag in
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
}
