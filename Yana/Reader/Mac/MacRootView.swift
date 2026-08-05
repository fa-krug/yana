import SwiftData
import SwiftUI

/// Which pane owns keyboard focus in the Mac window (Mail-style two-pane model).
enum MacFocusPane: Hashable { case sidebar, reader }

/// The Mac (Mac Catalyst) window: a two-column `NavigationSplitView` with the article list
/// permanently in the sidebar and the reader in the detail pane. This is the structural difference
/// from iOS — where the list is a sheet over a full-screen swipe pager — while everything below the
/// UI (aggregation, sync, the block reader) is shared.
struct MacRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var model = TimelineModel()
    @State private var settings = AppSettings()
    @State private var speech = ReaderSpeechController()
    @FocusState private var focusedPane: MacFocusPane?
    /// Keep the article-list sidebar open by default (and after relaunch) — it is the primary
    /// navigation on the Mac, not a collapsible drawer.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Mirrors the busy state so the toolbar spinner can animate in/out (the source observable is
    /// mutated outside an animation transaction, so we re-drive it here inside `withAnimation`).
    @State private var showSpinner = false
    /// Keeps the spinner up for a minimum interval so a sub-second update doesn't flash it.
    @State private var spinnerHoldTask: Task<Void, Never>?
    /// Creating a feed is a sheet here too (matching Add Tag and the Feeds pane), not the separate
    /// window it used to be — this window is simply where the empty-library and sidebar CTAs live.
    @State private var showingCreateFeed = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebarView(model: model, settings: settings,
                           onCreateFeed: { showingCreateFeed = true },
                           focusedPane: $focusedPane)
                .navigationSplitViewColumnWidth(
                    min: SidebarWidth.min, ideal: restoredSidebarWidth, max: SidebarWidth.max)
                .navigationTitle("Yana")
        } detail: {
            detail
                .toolbar { toolbar }
        }
        .accessibilityIdentifier("mac.window.root")
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                ManagementWebView(
                    serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!,
                    path: "/feeds/new"
                )
            }
        }
        .toast($model.toast)
        // Scene-wide (not tied to which view has focus) so ⌘↑/⌘↓ move the article even when the
        // UIKit reader in the detail pane holds first responder.
        .focusedSceneValue(\.timelineModel, model)
        .focusedSceneValue(\.readerSpeech, speech)
        .onAppear {
            model.configure(modelContext: modelContext, store: store)
            model.applyTimeline()
            focusedPane = .sidebar
            #if DEBUG
            // Pin the window to a fixed size when capturing App Store screenshots. Main window
            // only — the Settings window is captured at its natural size and composited.
            MacScreenshotWindow.applyWindowGeometryIfRequested()
            #endif
        }
        .onChange(of: store.summaries) { _, _ in model.applyTimeline() }
        .onChange(of: UpdateActivity.shared.isUpdating || model.isSummarizing) { _, busy in
            if busy {
                spinnerHoldTask?.cancel()
                spinnerHoldTask = nil
                withAnimation(.easeInOut(duration: 0.2)) { showSpinner = true }
            } else {
                // Hold the spinner briefly so a sub-second update doesn't flash on and off.
                spinnerHoldTask?.cancel()
                spinnerHoldTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled,
                          !(UpdateActivity.shared.isUpdating || model.isSummarizing) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { showSpinner = false }
                }
            }
        }
        .onChange(of: settings.disabledTagNames) { _, _ in model.recomputeFilter(); model.clampIndex() }
        .onChange(of: settings.includeUntagged) { _, _ in model.recomputeFilter(); model.clampIndex() }
        .onChange(of: settings.disabledFeedNames) { _, _ in model.recomputeFilter(); model.clampIndex() }
        .onChange(of: settings.starredOnly) { _, _ in model.recomputeFilter(); model.clampIndex() }
        .onDisappear {
            spinnerHoldTask?.cancel()
            spinnerHoldTask = nil
        }
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
                onRefresh: { model.triggerRefresh() },
                isFocused: focusedPane == .reader,
                onEscape: { focusedPane = .sidebar }
            )
            .ignoresSafeArea()
        }
    }

    /// The four article actions live in **one** `ControlGroup`, which is the system's joined toolbar
    /// group: it draws the shared capsule and the segment spacing itself, replacing the hand-rolled
    /// `glassEffect` pill this used to be. `ToolbarItemGroup` is *not* the equivalent on Catalyst —
    /// verified: its members render as separate round buttons, not a group. The overflow `Menu`
    /// deliberately stays outside as its own item.
    ///
    /// The `ControlGroup` must be hosted **directly** by a `ToolbarItem`. Nested inside a
    /// `ToolbarItemGroup` (as it was before commit 0cf55dc) it renders its content empty once the
    /// toolbar re-validates, which is the blank-pill bug that motivated hand-rolling in the first
    /// place; hosted directly it renders its segments.
    ///
    /// Two constraints shape the contents: the item set must stay constant, because
    /// adding/removing an item makes Catalyst re-validate the toolbar and flicker — hence the
    /// "Update all" button cross-fades its icon to a spinner in place rather than a spinner item
    /// appearing beside it — and the icons stay in one visual family (no mixed `.circle` variants),
    /// which is what made the old pill read as a jumble.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    if let article = model.selectedArticle() { model.toggleStar(article) }
                } label: {
                    Label(isSelectedStarred ? "Unstar" : "Star",
                          systemImage: isSelectedStarred ? "star.fill" : "star")
                        .macToolbarIcon()
                }
                .disabled(model.selectedSummary == nil)
                .help(Text(isSelectedStarred ? "Unstar" : "Star"))

                Button {
                    if let article = model.selectedArticle() { toggleSpeech(article) }
                } label: {
                    Label("Read Aloud",
                          systemImage: speech.state == .speaking ? "pause.fill" : "play.fill")
                        .macToolbarIcon()
                }
                .disabled(model.selectedSummary == nil)
                .help(Text("Read Aloud"))

                Button {
                    if let article = model.selectedArticle() { model.openWebsite(article) }
                } label: {
                    Label("Open Page", systemImage: "safari").macToolbarIcon()
                }
                .disabled(model.selectedSummary == nil)
                .help(Text("Open Page"))

                updateButton
            }
        }

        // The overflow menu stays its OWN toolbar item, never a segment of the group: it is a
        // pull-down, not a peer action, and a lone item's label padding keeps it a round button
        // rather than an upright oval.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { openWindow(id: WindowID.settings, value: true) } label: { Label("Settings", systemImage: "gearshape") }
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
                    } label: { Label("Reload", systemImage: "arrow.trianglehead.2.clockwise") }
                    Button {
                        if let article = model.selectedArticle() { model.copyLink(article) }
                    } label: { Label("Copy link", systemImage: "link") }
                }
            } label: {
                Label("More", systemImage: "ellipsis").macToolbarIcon()
            }
            // A pull-down chevron beside the ellipsis is redundant — the glyph already reads as
            // "more". `.menuIndicator(.hidden)` is the standard way to drop it.
            .menuIndicator(.hidden)
            .help(Text("More"))
        }
    }

    private var isSelectedStarred: Bool { model.selectedSummary?.isStarred ?? false }

    /// "Update all", whose icon cross-fades to a spinner while a run is in flight so the busy
    /// indicator sits inside the group without changing the item set or the group's width (both
    /// children stay laid out — only their opacity changes).
    private var updateButton: some View {
        Button {
            model.triggerRefresh()
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(showSpinner ? 0 : 1)
                ProgressView().controlSize(.small).opacity(showSpinner ? 1 : 0)
            }
            .macToolbarIcon()
        }
        .disabled(showSpinner)
        .help(Text("Update all"))
        .accessibilityLabel(showSpinner ? Text("Updating") : Text("Update all"))
    }

    /// The sidebar's launch width: the last persisted value clamped to bounds, or the ideal default
    /// when no value has been stored yet (stored value == 0 is the UserDefaults zero-default). This
    /// only seeds the column's `ideal:` at first layout — live drags are captured separately by
    /// `widthReader` and persisted for the *next* launch, not fed back into the column this session.
    private var restoredSidebarWidth: CGFloat {
        let stored = CGFloat(settings.macSidebarWidth)
        return stored > 0 ? SidebarWidth.clamp(stored) : SidebarWidth.ideal
    }

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
    @FocusState.Binding var focusedPane: MacFocusPane?

    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResults: [ArticleSummary]?
    /// Drives `.scrollPosition(id:)` below. Mirrors `model.scrollTarget.id` — see that modifier's
    /// `.onChange` for why a repeated request for the same id still needs to reach the List.
    @State private var scrollAnchorID: String?
    /// The last `scrollTarget.token` applied, so a delivery that doesn't change the token (a plain
    /// SwiftUI re-render, not a new request) doesn't re-trigger a scroll.
    @State private var lastAppliedScrollToken: Int?

    /// Browsing shows the model's filtered timeline; a live search swaps in predicate-fetched rows,
    /// re-run through the same tag/feed filter so the sidebar stays a subset of the reader timeline.
    ///
    /// Cached, not a computed property (review finding 2): `.scrollPosition(id:)` below is a
    /// two-way `Binding`, so SwiftUI writes `scrollAnchorID` back on every row-crossing-centre event
    /// while the user scrolls — each write re-evaluates this view's `body`. A computed `displayed`
    /// re-ran the `TagFilter`/`FeedFilter` passes (and, while a search is active, re-filtered the
    /// search results) on every one of those scroll-driven passes, on top of the `ForEach` identity
    /// diff `body` always pays. Caching it means a scroll-driven `body` pass is O(1) here; the value
    /// only actually changes when one of its real inputs does — see `recomputeDisplayed()`.
    @State private var displayed: [ArticleSummary] = []

    /// Extra vertical room per sidebar row — the AppKit-backed source list packs rows tightly by
    /// default, so the article list reads as a cramped wall of text. iOS never renders this view.
    private static let rowInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 12)

    /// A calmer selection fill than the raw accent: the brand lavender mixed toward black so the
    /// focused pill reads as a deep violet instead of a glaring neon block, while white row text
    /// stays legible on top. `mix` resolves per-appearance, so it tracks light/dark like the accent.
    /// The mix is deliberately shallow — the accent asset itself is already a darkened lavender, so
    /// the old 0.3 would compound into near-black here.
    private static var selectionTint: Color { Color.accentColor.mix(with: .black, by: 0.18) }

    var body: some View {
        // The List must be the DIRECT child of the NavigationSplitView sidebar column for the system
        // to give it the source-list chrome (translucent material, inset rounded selection, no
        // separators) — a prior version of this view wrapped it in a ScrollViewReader precisely to
        // scroll to the selection, and that wrapper was what suppressed the chrome; it was removed
        // for exactly that reason. `.scrollPosition(id:anchor:)` below is a modifier applied
        // directly to this same List (like `.listStyle(.sidebar)` or `.searchable` already are), not
        // a wrapping container, so it programmatically scrolls the selected row into view without
        // repeating that failure.
        List(selection: $model.selection) {
            ForEach(displayed) { summary in
                MacArticleRow(summary: summary, model: model,
                              isSelected: model.selection == summary.identifier)
                    .listRowInsets(Self.rowInsets)
                    .tag(summary.identifier)
            }
        }
        // Screenshot/UI-test navigation target. EN/DE labels differ, so tests key off identifiers.
        .accessibilityIdentifier("mac.sidebar.list")
        .listStyle(.sidebar)
        .onAppear { recomputeDisplayed() }
        // `displayed`'s real inputs: the model's filtered timeline, the live search results, and —
        // only relevant while a search is active, since browsing already reads `model.filteredArticles`
        // straight through — the tag/feed filter settings `recomputeDisplayed()` re-applies on top of
        // `searchResults`. None of these fire on a mere scroll (see `displayed`'s doc comment).
        .onChange(of: model.filteredArticles) { _, _ in recomputeDisplayed() }
        .onChange(of: searchResults) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.starredOnly) { _, _ in recomputeDisplayed() }
        .scrollPosition(id: $scrollAnchorID, anchor: .center)
        .onChange(of: model.scrollTarget) { _, target in
            guard let target, target.token != lastAppliedScrollToken else { return }
            lastAppliedScrollToken = target.token
            if scrollAnchorID == target.id {
                // Same id as already applied (e.g. the launch anchor restore immediately followed by
                // a remote anchor for that same article): reassigning the identical value wouldn't
                // change `scrollAnchorID` at all, so SwiftUI would never re-issue the scroll. Bounce
                // through `nil` first so the following assignment is a genuine change.
                scrollAnchorID = nil
                Task { @MainActor in scrollAnchorID = target.id }
            } else {
                scrollAnchorID = target.id
            }
        }
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
        .safeAreaInset(edge: .top) {
            // Re-identified by `.id()` on a CloudKit remote-change bump (see `LibraryRevision`) so
            // its `@Query` re-fetches — `@Query` never sees `.NSPersistentStoreRemoteChange` on its
            // own. No local `@State` here to lose: `settings` is passed in and owned elsewhere.
            MacFilterBar(settings: settings)
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        .task(id: debouncedSearch) { await runSearch() }
        .focused($focusedPane, equals: .sidebar)
        .onKeyPress(.return) {
            guard model.selectedSummary != nil else { return .ignored }
            focusedPane = .reader
            return .handled
        }
        .background(widthReader)
    }

    @ViewBuilder private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width) { _, newWidth in
                    let clamped = SidebarWidth.clamp(newWidth)
                    // Only persist meaningful changes to avoid churn on every layout tick.
                    if abs(clamped - CGFloat(settings.macSidebarWidth)) > 1 {
                        settings.macSidebarWidth = Double(clamped)
                    }
                }
        }
    }

    /// Recomputes the cached `displayed` from its real inputs. Called from the `onChange`/`onAppear`
    /// hooks above, never from `body` itself — that's the whole point of caching it (review finding 2).
    private func recomputeDisplayed() {
        guard let searchResults else { displayed = model.filteredArticles; return }
        let byTag = TagFilter.apply(to: searchResults,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        displayed = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
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
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)
        searchResults = matches.map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
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
            toggle(String(localized: "Starred Only"), isOn: settings.starredOnly) {
                settings.starredOnly = $0
            }
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
                    settings.starredOnly = false
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
    let model: TimelineModel
    let isSelected: Bool
    @State private var isHovering = false

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
                        Text(summary.feedName).fontWeight(.medium).foregroundStyle(feedNameColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(summary.createdAt, style: .date).foregroundStyle(.tertiary)
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
        .background(hoverBackground)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
    }

    /// The feed name is accent-tinted, which is exactly the hue the selection pill is derived from —
    /// on the selected row it would disappear into its own background. Invert it there to the white
    /// the system already draws the rest of the selected row's text in.
    private var feedNameColor: Color { isSelected ? .white : Color.accentColor }

    @ViewBuilder private var hoverBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHovering && !isSelected ? Color.primary.opacity(0.06) : Color.clear)
            .padding(.horizontal, -6)
    }

    @ViewBuilder private var contextMenuItems: some View {
        Button {
            if let article = model.resolve(summary) { model.toggleStar(article) }
        } label: {
            Label(summary.isStarred ? "Unstar" : "Star",
                  systemImage: summary.isStarred ? "star.slash" : "star")
        }

        Button {
            if let article = model.resolve(summary) { model.openWebsite(article) }
        } label: { Label("Open in Browser", systemImage: "safari") }

        Button {
            if let article = model.resolve(summary) { model.copyLink(article) }
        } label: { Label("Copy link", systemImage: "link") }

        Divider()

        Button {
            if let article = model.resolve(summary) { model.forceUpdateArticle(article) }
        } label: { Label("Reload", systemImage: "arrow.trianglehead.2.clockwise") }

        if model.aiReady {
            Button {
                if let article = model.resolve(summary) { model.summarize(article) }
            } label: { Label("Summarize", systemImage: "sparkles") }
                .disabled(model.isSummarizing)
        }
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
