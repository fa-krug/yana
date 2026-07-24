import SwiftData
import SwiftUI

/// The Mac (Mac Catalyst) window: a two-column `NavigationSplitView` with the article list
/// permanently in the sidebar and the reader in the detail pane. This is the structural difference
/// from iOS — where the list is a sheet over a full-screen swipe pager — while everything below the
/// UI (aggregation, sync, the block reader) is shared.
struct MacRootView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    @State private var model = TimelineModel()
    @State private var settings = AppSettings()
    @State private var speech = ReaderSpeechController()
    @State private var showingCreateFeed = false
    @State private var showingSettings = false
    /// Keep the article-list sidebar open by default (and after relaunch) — it is the primary
    /// navigation on the Mac, not a collapsible drawer.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Mirrors the busy state so the toolbar spinner can animate in/out (the source observable is
    /// mutated outside an animation transaction, so we re-drive it here inside `withAnimation`).
    @State private var showSpinner = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebarView(model: model, settings: settings, onCreateFeed: { showingCreateFeed = true })
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
                .navigationTitle("Yana")
        } detail: {
            detail
                .toolbar { toolbar }
        }
        .toast($model.toast)
        // Scene-wide (not tied to which view has focus) so ⌘↑/⌘↓ move the article even when the
        // UIKit reader in the detail pane holds first responder. `settingsOpen` stands them down.
        .focusedSceneValue(\.timelineModel, model)
        .focusedSceneValue(\.readerSpeech, speech)
        .focusedSceneValue(\.settingsOpen, showingSettings)
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                FeedEditorView(feed: nil) { newFeed in model.createFeed(newFeed) }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsScreenView(onRestartOnboarding: {
                    showingSettings = false
                    appState.showWelcome = true
                })
            }
            .frame(minWidth: 520, minHeight: 600)
        }
        .fullScreenCover(isPresented: $appState.showWelcome) {
            WelcomeView(onFinish: {
                settings.hasCompletedOnboarding = true
                appState.showWelcome = false
            })
            .interactiveDismissDisabled()
        }
        .onAppear {
            model.configure(modelContext: modelContext, store: store)
            model.applyTimeline()
        }
        .onChange(of: store.summaries) { _, _ in model.applyTimeline() }
        .onChange(of: UpdateActivity.shared.isUpdating || model.isSummarizing) { _, busy in
            withAnimation(.snappy) { showSpinner = busy }
        }
        .onChange(of: settings.disabledTagNames) { _, _ in model.recomputeFilter(); model.clampIndex() }
        .onChange(of: settings.includeUntagged) { _, _ in model.recomputeFilter(); model.clampIndex() }
        .onChange(of: settings.disabledFeedNames) { _, _ in model.recomputeFilter(); model.clampIndex() }
    }

    @ViewBuilder private var detail: some View {
        if model.filteredArticles.isEmpty {
            MacEmptyLibraryView(onCreateFeed: { showingCreateFeed = true })
        } else {
            MacReaderDetailView(
                articles: model.filteredArticles,
                index: model.currentIndex,
                resolveArticle: { model.resolve($0) },
                reloadToken: model.reloadToken,
                onRefresh: { model.triggerRefresh() }
            )
            .ignoresSafeArea()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Reload, star, play, website — individual toolbar buttons. These were a joined
            // `ControlGroup`, but a `ControlGroup` nested in a Mac Catalyst window toolbar renders
            // its content EMPTY after the toolbar re-validates (e.g. once a sync repopulates the
            // detail pane) — leaving a blank pill while the sibling `Menu` below stays fine. Plain
            // toolbar buttons don't hit that bug. The item set stays constant, so the bar still
            // doesn't rebuild/flicker; while an update/summarize runs, the reload arrow spins in place.
            Button { model.triggerRefresh() } label: {
                Label("Update all", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: showSpinner)
            }
            .help(Text("Update all"))

            Button {
                if let article = model.selectedArticle() { model.toggleStar(article) }
            } label: {
                Label(isSelectedStarred ? "Unstar" : "Star",
                      systemImage: isSelectedStarred ? "star.fill" : "star")
            }
            .help(Text(isSelectedStarred ? "Unstar" : "Star"))
            .disabled(model.selectedSummary == nil)

            Button {
                if let article = model.selectedArticle() { toggleSpeech(article) }
            } label: {
                Label("Read Aloud",
                      systemImage: speech.state == .speaking ? "pause.circle" : "play.circle")
            }
            .help(Text("Read Aloud"))
            .disabled(model.selectedSummary == nil)

            Button {
                if let article = model.selectedArticle() { model.openWebsite(article) }
            } label: {
                Label("Open Page", systemImage: "safari")
            }
            .help(Text("Open Page"))
            .disabled(model.selectedSummary == nil)

            Menu {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                if model.selectedSummary != nil {
                    Divider()
                    if model.aiReady {
                        Button {
                            if let article = model.selectedArticle() { model.summarize(article) }
                        } label: { Label("Summarize", systemImage: "sparkles") }
                            .disabled(model.isSummarizing)
                    }
                    Button {
                        if let article = model.selectedArticle() { model.forceUpdateArticle(article) }
                    } label: {
                        Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    Button {
                        if let article = model.selectedArticle() { model.copyLink(article) }
                    } label: { Label("Copy link", systemImage: "link") }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var isSelectedStarred: Bool { model.selectedSummary?.isStarred ?? false }

    /// Start narrating the selected article when idle; otherwise pause/resume. Speech is owned at the
    /// window level (not the swappable detail child), so it keeps reading the article it was started
    /// on even as the user clicks through the list — it only switches when explicitly restarted here.
    private func toggleSpeech(_ article: Article) {
        if speech.state == .idle {
            speech.speak(article)
        } else {
            speech.togglePauseResume()
        }
    }
}

/// The sidebar: a filter menu pinned at the top, a search field, and the article list bound to the
/// model's selection so ↑/↓ (and the Next/Previous menu commands) move the reader.
private struct MacSidebarView: View {
    @Bindable var model: TimelineModel
    /// Shared with `MacRootView` so a filter toggle here fires its `.onChange` (AppSettings
    /// observation is per-instance — a separate instance would not notify the root).
    let settings: AppSettings
    let onCreateFeed: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResults: [ArticleSummary]?

    /// Extra vertical room per sidebar row — the AppKit-backed source list packs rows tightly by
    /// default, so the article list reads as a cramped wall of text. iOS never renders this view.
    private static let rowInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 12)

    /// A calmer selection fill than the raw accent: the brand lavender mixed toward black so the
    /// focused pill reads as a deep violet instead of a glaring neon block, while white row text
    /// stays legible on top. `mix` resolves per-appearance, so it tracks light/dark like the accent.
    private static var selectionTint: Color { Color.accentColor.mix(with: .black, by: 0.3) }

    /// Browsing shows the model's filtered timeline; a live search swaps in predicate-fetched rows,
    /// re-run through the same tag/feed filter so the sidebar stays a subset of the reader timeline.
    private var displayed: [ArticleSummary] {
        guard let searchResults else { return model.filteredArticles }
        let byTag = TagFilter.apply(to: searchResults,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        return FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    var body: some View {
        // The List must be the DIRECT child of the NavigationSplitView sidebar column for the system
        // to give it the source-list chrome (translucent material, inset rounded selection, no
        // separators). Wrapping it in a ScrollViewReader defeats that, so we let the List drive its
        // own selection-follow scrolling rather than a reader proxy.
        List(selection: $model.selection) {
            ForEach(displayed) { summary in
                MacArticleRow(summary: summary)
                    .listRowInsets(Self.rowInsets)
                    .tag(summary.identifier)
            }
        }
        .listStyle(.sidebar)
        // The selection highlight follows the tint. The brand accent is a bright lavender that
        // fills the whole selected pill at full saturation — glaring against the dark sidebar — so
        // damp it toward a deeper violet for the sidebar only. Derived from the accent so it stays
        // on-brand and adapts to light/dark; iOS is untouched (this is the Mac window).
        .tint(Self.selectionTint)
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search articles"))
        .overlay {
            if displayed.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Articles", systemImage: "tray",
                                           description: Text("No articles yet. Add feeds, then update."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .safeAreaInset(edge: .top) { MacFilterBar(settings: settings) }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        .task(id: debouncedSearch) { await runSearch() }
    }

    private func runSearch() async {
        let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = nil; return }
        var descriptor = FetchDescriptor<Article>(
            predicate: ArticleListSearch.predicate(for: q),
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        searchResults = matches.map(ArticleSummary.init)
    }
}

/// The pinned tag/feed filter control at the top of the sidebar (the Mac home for what is a sheet on
/// iOS). A pull-down `Menu` of toggles that write straight to the shared `AppSettings` filter.
private struct MacFilterBar: View {
    let settings: AppSettings
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @Query(sort: \Feed.name) private var feeds: [Feed]

    private var isFiltering: Bool { settings.isTimelineFilterActive }

    var body: some View {
        Menu {
            Section("Tags") {
                ForEach(tags) { tag in
                    toggle(tag.name, isOn: !settings.disabledTagNames.contains(tag.name)) { active in
                        var set = settings.disabledTagNames
                        if active { set.remove(tag.name) } else { set.insert(tag.name) }
                        settings.disabledTagNames = set
                    }
                }
                toggle(String(localized: "Untagged"), isOn: settings.includeUntagged) {
                    settings.includeUntagged = $0
                }
            }
            if !feeds.isEmpty {
                Section("Feeds") {
                    ForEach(feeds) { feed in
                        toggle(feed.name, isOn: !settings.disabledFeedNames.contains(feed.name)) { active in
                            var set = settings.disabledFeedNames
                            if active { set.remove(feed.name) } else { set.insert(feed.name) }
                            settings.disabledFeedNames = set
                        }
                    }
                }
            }
            if isFiltering {
                Divider()
                Button("Clear All") {
                    settings.disabledTagNames = []
                    settings.disabledFeedNames = []
                    settings.includeUntagged = true
                }
            }
        } label: {
            Label("Filter", systemImage: isFiltering
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
    }
}

/// Sidebar row: feed logo, title, feed name · date, and a star marker. The logo is top-aligned so it
/// lines up with the first title line rather than floating against a two-line title.
private struct MacArticleRow: View {
    let summary: ArticleSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FeedLogoView(hash: summary.feedLogoHash, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(3)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !summary.feedName.isEmpty {
                        Text(summary.feedName).fontWeight(.medium).foregroundStyle(Color.accentColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(summary.date, style: .date).foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            if summary.isStarred {
                Spacer(minLength: 0)
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    .accessibilityLabel(Text("Starred"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Detail-pane state when the library is empty: a call to add the first feed.
private struct MacEmptyLibraryView: View {
    let onCreateFeed: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Articles", systemImage: "tray")
        } description: {
            Text("Add a feed to start reading.")
        } actions: {
            Button("Add Feed", action: onCreateFeed).buttonStyle(.borderedProminent)
        }
    }
}
