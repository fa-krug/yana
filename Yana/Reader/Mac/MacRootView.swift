import SwiftData
import SwiftUI

/// Which pane owns keyboard focus in the Mac window (Mail-style two-pane model).
enum MacFocusPane: Hashable { case sidebar, reader }

/// The Mac (Mac Catalyst) window: a two-column `NavigationSplitView` with the article list
/// permanently in the sidebar and the reader in the detail pane. This is the structural difference
/// from iOS — where the list is a sheet over a full-screen swipe pager — while everything below the
/// UI (aggregation, sync, the block reader) is shared.
struct MacRootView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(AppSettings.self) private var settings

    @State private var model: TimelineModel
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

    /// `TimelineModel` needs its `AppSettings` at construction time (its `anchorWriter` captures it
    /// immediately), before `@Environment` is resolved -- so the shared instance is threaded through
    /// here as a plain init parameter instead, sourced from `ContentView`'s own `@Environment`.
    init(appState: AppState, settings: AppSettings) {
        self.appState = appState
        _model = State(initialValue: TimelineModel(settings: settings))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebarView(model: model, settings: settings, focusedPane: $focusedPane)
                .navigationSplitViewColumnWidth(
                    min: SidebarWidth.min, ideal: restoredSidebarWidth, max: SidebarWidth.max)
                .navigationTitle("Yana")
        } detail: {
            detail
                .toolbar { toolbar }
        }
        .accessibilityIdentifier("mac.window.root")
        .safeAreaInset(edge: .top) {
            if showDemoBanner {
                DemoModeBanner(
                    onPairNow: {
                        appState.welcomeInitialStep = .server
                        openWindow(id: WindowID.welcome, value: true)
                    },
                    onDismiss: { settings.hasDismissedDemoBanner = true }
                )
            }
        }
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                ManagementWebView(
                    serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!,
                    path: "/feeds/new",
                    title: nil,
                    showsBackButton: true
                )
            }
            // Matches `MacSettingsWindow`'s own sizing. Left unset, this sheet takes Catalyst's
            // default small form-sheet size -- a cramped, floating card in the middle of the
            // window, dead space all around -- since neither `ManagementWebView` nor its wrapping
            // `NavigationStack` requests a size of its own.
            .frame(minWidth: 700, minHeight: 560)
        }
        .sheet(isPresented: Binding(
            get: { model.openOnServerPath != nil },
            set: { if !$0 { model.openOnServerPath = nil } }
        )) {
            if let path = model.openOnServerPath {
                NavigationStack {
                    ManagementWebView(
                        serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!,
                        path: path,
                        title: nil,
                        showsBackButton: true
                    )
                }
                .frame(minWidth: 700, minHeight: 560)
            }
        }
        .alert(
            String(localized: "Delete Article?"),
            isPresented: Binding(
                get: { model.summaryPendingDelete != nil },
                set: { if !$0 { model.summaryPendingDelete = nil } }
            )
        ) {
            if let summary = model.summaryPendingDelete {
                Button(String(localized: "Delete"), role: .destructive) { model.deleteArticle(summary) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let summary = model.summaryPendingDelete {
                Text(String(localized: "Delete \u{201C}\(summary.title)\u{201D}? This cannot be undone."))
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
        .onChange(of: settings.pendingRemoteReadingPosition) { _, _ in model.handleRemotePositionUpdate() }
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
        .onChange(of: settings.readFilter) { _, _ in model.refilterKeepingCurrentArticle() }
        // The only observer of finished operations on Mac -- there is exactly one detail pane, so
        // a second observer elsewhere would show the same outcome as two toasts. No haptics here:
        // Catalyst has none. Delegates to `TimelineModel.applyOperationOutcome` because
        // `reloadToken` is `private(set)`. Keyed on the event's `sequence` rather than the outcome
        // value, so two identical consecutive outcomes are both delivered -- see
        // `OperationOutcomeEvent`.
        .onChange(of: OperationMonitor.shared.lastOutcomeEvent?.sequence) { _, _ in
            guard let outcome = OperationMonitor.shared.lastOutcomeEvent?.outcome else { return }
            model.applyOperationOutcome(outcome)
        }
        .onDisappear {
            spinnerHoldTask?.cancel()
            spinnerHoldTask = nil
        }
    }

    @ViewBuilder private var detail: some View {
        if appState.isPerformingInitialSync {
            InitialSyncLoadingView()
        } else if appState.initialSyncFailed, !settings.hasCompletedInitialSync {
            InitialSyncFailedView { retryInitialSync() }
        } else if model.filteredArticles.isEmpty {
            MacEmptyLibraryView(
                isPaired: AuthenticatedClient.current() != nil,
                onCreateFeed: { showingCreateFeed = true },
                onPairServer: {
                    appState.welcomeInitialStep = .server
                    openWindow(id: WindowID.welcome, value: true)
                }
            )
        } else {
            MacReaderDetailView(
                articles: model.filteredArticles,
                index: model.currentIndex,
                resolveArticle: { model.resolve($0) },
                reloadToken: model.reloadToken,
                findRequest: model.findRequest,
                onRefresh: { model.triggerRefresh() },
                isFocused: focusedPane == .reader,
                onEscape: { focusedPane = .sidebar }
            )
            .ignoresSafeArea()
        }
    }

    /// The article actions and the overflow menu are each their **own** `ToolbarItem`, grouped only
    /// for placement via `ToolbarItemGroup` — matching MySquad's Mac toolbars (its `ProjectsView`,
    /// for one), which never joins icon buttons into a `ControlGroup` capsule. Catalyst then renders
    /// each as its own separate round button with the system's own spacing between them, and — because
    /// nothing pads the label independently of the button's own hit/focus region — the keyboard-focus
    /// and pointer-hover ring the system draws covers the whole button, not just the SF Symbol glyph.
    ///
    /// This replaces an earlier hand-joined `ControlGroup` capsule (itself replacing a hand-rolled
    /// `glassEffect` pill): visually tidy, but each segment's focus ring only ever framed its glyph,
    /// not the segment — which is the bug this reverts. A bare `Image(systemName:)` label (no visible
    /// title, `accessibilityLabel`/`.help` carry the name) is what MySquad's own Mac toolbar buttons
    /// use, too.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let article = model.selectedArticle() { model.toggleStar(article) }
            } label: {
                Image(systemName: isSelectedStarred ? "star.fill" : "star")
            }
            .disabled(model.selectedSummary == nil)
            .help(Text(isSelectedStarred ? "Unstar" : "Star"))
            .accessibilityLabel(Text(isSelectedStarred ? "Unstar" : "Star"))

            Button {
                if let article = model.selectedArticle() { toggleSpeech(article) }
            } label: {
                Image(systemName: speech.state == .speaking ? "pause.fill" : "play.fill")
            }
            .disabled(model.selectedSummary == nil)
            .help(Text("Read Aloud"))
            .accessibilityLabel(Text("Read Aloud"))

            // Dropped while unpaired/demo: those articles' `url`s aren't real pages worth
            // leaving the app for.
            if model.hasServer {
                Button {
                    if let article = model.selectedArticle() { model.openWebsite(article) }
                } label: {
                    Image(systemName: "safari")
                }
                .disabled(model.selectedSummary == nil)
                .help(Text("Open in Browser"))
                .accessibilityLabel(Text("Open in Browser"))
            }

            if model.hasServer {
                updateButton
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                // ⌘, is now claimed by the app-menu Settings item (`YanaCommands`'s
                // `.appSettings` command group) — this button keeps the action but not the shortcut,
                // so only one control claims it.
                Button { openWindow(id: WindowID.settings, value: true) } label: { Label("Settings", systemImage: "gearshape") }
                if model.selectedSummary != nil {
                    Divider()
                    let article = model.selectedArticle()
                    let config = ReaderMenuBuilder.config(
                        hasURL: !(article?.url.isEmpty ?? true), aiReady: model.aiReady,
                        hasServerArticle: model.hasServer && article?.serverID != nil
                    )
                    if config.showSummarize {
                        Button {
                            if let article { model.summarize(article) }
                        } label: { Label("Summarize", systemImage: "sparkles") }
                            .disabled(model.isSummarizing)
                    }
                    if config.showReload {
                        Button {
                            if let article { model.forceUpdateArticle(article) }
                        } label: { Label("Reload", systemImage: "arrow.trianglehead.2.clockwise") }
                    }
                    if config.showCopyLink {
                        Button {
                            if let article { model.copyLink(article) }
                        } label: { Label("Copy link", systemImage: "link") }
                    }
                    if config.showOpenOnServer {
                        Button {
                            if let article { model.openOnServer(article) }
                        } label: { Label("Open on Server", systemImage: "server.rack") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            // A pull-down chevron beside the ellipsis is redundant — the glyph already reads as
            // "more". `.menuIndicator(.hidden)` is the standard way to drop it.
            .menuIndicator(.hidden)
            .help(Text("More"))
        }
    }

    private var isSelectedStarred: Bool { model.selectedSummary?.isStarred ?? false }

    private var showDemoBanner: Bool {
        settings.hasSkippedServerPairing && !settings.hasDismissedDemoBanner && AuthenticatedClient.current() == nil
    }

    /// "Update all", whose icon cross-fades to a plain, indeterminate spinner while a run is in
    /// flight so the busy indicator sits inside the group without changing the item set or the
    /// group's width (both children stay laid out — only their opacity changes). While the spinner
    /// shows, the button stays enabled but changes meaning: it opens the server's page for the
    /// job in flight instead of triggering another run (`TimelineModel.showProgressOnServer`).
    private var updateButton: some View {
        Button {
            if showSpinner {
                model.showProgressOnServer()
            } else {
                model.triggerRefresh()
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(showSpinner ? 0 : 1)
                // On Catalyst a ProgressView bridges to a UIActivityIndicatorView that -- unlike
                // the one ReaderArticleViewController builds by hand and explicitly disables
                // interaction on -- accepts touches by default, so it swallows the tap meant for
                // the Button underneath: nothing happened when this spinner was tapped while
                // showing. allowsHitTesting(false) lets the touch fall through to the button.
                ProgressView().controlSize(.small).opacity(showSpinner ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .help(showSpinner ? Text("Show progress on server") : Text("Update all"))
        .accessibilityLabel(showSpinner ? Text("Show progress on server") : Text("Update all"))
    }

    /// The sidebar's launch width: the last persisted value clamped to bounds, or the ideal default
    /// when no value has been stored yet (stored value == 0 is the UserDefaults zero-default). This
    /// only seeds the column's `ideal:` at first layout — live drags are captured separately by
    /// `widthReader` and persisted for the *next* launch, not fed back into the column this session.
    private var restoredSidebarWidth: CGFloat {
        let stored = CGFloat(settings.macSidebarWidth)
        return stored > 0 ? SidebarWidth.clamp(stored) : SidebarWidth.ideal
    }

    /// Retries the blocking first-sync gate after `InitialSyncFailedView`'s "Try Again" button.
    private func retryInitialSync() {
        guard let client = AuthenticatedClient.current() else { return }
        appState.initialSyncFailed = false
        Task {
            await InitialSyncGate.run(
                container: AppContainer.shared, client: client,
                articleStore: store, appState: appState, settings: settings
            )
        }
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
struct MacSidebarView: View {
    @Bindable var model: TimelineModel
    /// Shared with `MacRootView` so a filter toggle here fires its `.onChange` (AppSettings
    /// observation is per-instance — a separate instance would not notify the root).
    let settings: AppSettings
    @FocusState.Binding var focusedPane: MacFocusPane?

    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResults: [ArticleSummary]?
    /// Focused by the ⌘F Find command (`model.searchFocusToken`) via the `.onChange` below.
    @FocusState private var searchFieldFocused: Bool
    /// The last `scrollTarget.token` applied, so a delivery that doesn't change the token (a plain
    /// SwiftUI re-render, not a new request) doesn't re-trigger a scroll.
    @State private var lastAppliedScrollToken: Int?

    /// One-shot gate for the launch case: the sidebar's rows are hidden (`.opacity`) until the very
    /// first scroll request -- the anchor restore -- has actually landed on screen, so the sidebar
    /// opens already parked on the current article instead of visibly jumping there from the top.
    /// See `scrollToTarget(_:proxy:)` for why this needs a retry loop and a visibility check at all,
    /// rather than a single `proxy.scrollTo`, and its doc comment for why the once-proven-broken
    /// `ScrollViewReader` wrapper below is back: this mirrors `ManagedList`'s identical technique
    /// (`Yana/Views/Config/ManagedList.swift`), the one place in this codebase that already solved
    /// "open a List already parked on a specific row" reliably.
    @State private var isRevealed = false
    /// Set once the launch anchor's scroll has been requested, so every later request (Next/Previous
    /// Article, a remote anchor arriving live, the reanchor self-heal) takes the plain, no-hiding
    /// path -- the sidebar is already on screen by then, so there is nothing to reveal.
    @State private var hasHandledFirstScrollRequest = false
    /// Set once a `scrollTo` call has been given a frame to take effect. The reveal condition below
    /// ignores anything the target row reports before that: a target near the top is realized before
    /// any scrolling, and revealing on that first report would show it in its pre-scroll place and
    /// let the centering scroll shift it in front of the user.
    @State private var scrollHasSettled = false
    /// The target row's last reported frame, kept so the reveal can be re-evaluated when
    /// `scrollHasSettled` flips -- in a list short enough that the scroll moves nothing, the row
    /// reports its position once and never again.
    @State private var targetRowFrame: CGRect?
    /// The List's own frame, against which the target row's frame is tested for on-screen-ness.
    @State private var listFrame: CGRect = .zero

    /// Browsing shows the model's filtered timeline; a live search swaps in predicate-fetched rows,
    /// re-run through the same tag/feed filter so the sidebar stays a subset of the reader timeline.
    ///
    /// Cached, not a computed property (review finding 2): re-running the `TagFilter`/`FeedFilter`
    /// passes (and, while a search is active, re-filtering the search results) on every `body` pass
    /// would be wasted work on top of the `ForEach` identity diff `body` always pays. Caching it
    /// means a `body` pass unrelated to filtering is O(1) here; the value only actually changes when
    /// one of its real inputs does — see `recomputeDisplayed()`.
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
        // `ScrollViewReader { List { ... } }`: an earlier version of this view used exactly this
        // wrapper and, per a since-superseded assumption in this file's history, it was blamed for
        // suppressing the sidebar's native source-list chrome (translucent material, inset rounded
        // selection, no separators) and replaced with `.scrollPosition(id:)` applied directly to the
        // List instead. That replacement is what this fix reverts: `.scrollPosition(id:)` can only
        // scroll to a row the List has already laid out, so a request delivered the instant its row's
        // data arrives (the launch anchor restore, above all) races the List's own layout and is
        // silently dropped -- which is exactly why the sidebar opened at the top instead of parked on
        // the current article. `ManagedList` (`Yana/Views/Config/ManagedList.swift`) solves this exact
        // problem for the iOS article list with `ScrollViewReader` + a retry loop + hiding the rows
        // until the target row is confirmed on screen; this reapplies that same proven technique here.
        // **This needs a one-time manual check that the sidebar chrome still looks right** — the
        // original "breaks chrome" finding predates that reveal-gating discovery and was bundled in a
        // commit that also fixed an unrelated Mac-idiom bug, so it was never re-isolated and retested.
        ScrollViewReader { proxy in
            sidebarList(proxy: proxy)
                .toolbar { sidebarToolbar }
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
    }

    /// Split out from `body` so the type checker resolves this half of the modifier chain
    /// independently from the other half — adding `.toolbar` to the combined chain pushed it past
    /// the compiler's inference timeout.
    @ViewBuilder
    private func sidebarList(proxy: ScrollViewProxy) -> some View {
        List(selection: $model.selection) {
            ForEach(displayed) { summary in
                MacArticleRow(summary: summary, model: model,
                              isSelected: model.selection == summary.stableKey)
                    .listRowInsets(Self.rowInsets)
                    .tag(summary.stableKey)
                    // Only the row currently being scrolled to reports its position, and only
                    // while the launch reveal is still pending -- every other row pays nothing.
                    .modifier(SidebarTargetRowProbe(
                        isTarget: !isRevealed && summary.identifier == model.scrollTarget?.id,
                        onPosition: targetRowDidReport))
            }
        }
        // Screenshot/UI-test navigation target. EN/DE labels differ, so tests key off identifiers.
        .accessibilityIdentifier("mac.sidebar.list")
        .listStyle(.sidebar)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
        // Rows stay invisible (but laid out, so the scroll below can resolve them) until the
        // launch anchor has been scrolled to -- see `scrollToTarget(_:proxy:)`.
        .opacity(isRevealed ? 1 : 0)
        .onAppear {
            recomputeDisplayed()
            revealIfNothingToRestore()
            scheduleRevealFallback()
        }
        // `displayed`'s real inputs: the model's filtered timeline, the live search results, and —
        // only relevant while a search is active, since browsing already reads `model.filteredArticles`
        // straight through — the tag/feed filter settings `recomputeDisplayed()` re-applies on top of
        // `searchResults`.
        .onChange(of: model.filteredArticles) { _, _ in recomputeDisplayed(); revealIfNothingToRestore() }
        // An empty library's only signal: `summaries` never changes, so this is what lets the
        // "No Articles" state show without waiting on `scheduleRevealFallback`.
        .onChange(of: store.hasLoaded) { _, _ in revealIfNothingToRestore() }
        .onChange(of: searchResults) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.starredOnly) { _, _ in recomputeDisplayed() }
        .onChange(of: settings.readFilter) { _, _ in recomputeDisplayed() }
        .onChange(of: model.scrollTarget) { _, target in
            guard let target, target.token != lastAppliedScrollToken else { return }
            lastAppliedScrollToken = target.token
            scrollToTarget(target.id, proxy: proxy)
        }
        // The selection highlight follows the tint. The brand accent is a bright lavender that
        // fills the whole selected pill at full saturation — glaring against the dark sidebar — so
        // damp it toward a deeper violet for the sidebar only. Derived from the accent so it stays
        // on-brand and adapts to light/dark; iOS is untouched (this is the Mac window).
        .tint(Self.selectionTint)
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search articles"))
        .searchFocused($searchFieldFocused)
        .onChange(of: model.searchFocusToken) { _, _ in searchFieldFocused = true }
        .overlay {
            if displayed.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Articles", systemImage: "tray",
                                           description: Text("Pair a Yana Server that has feeds and articles configured."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    /// The filter menu lives in the sidebar's own toolbar, next to its native search field, instead
    /// of a hand-rolled labeled row above the list — that row rendered "Filter" as a text+icon pill
    /// (the system's default look for a labeled `Menu`), which read as an unstyled, oversized control
    /// against the dark source list. Hosting it as a `ToolbarItem` gets the same icon-only round
    /// button every other single Mac toolbar control in this app uses (`MacRootView.toolbar`).
    @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            MacFilterMenu(settings: settings)
        }
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
        displayed = TimelineFilterChain.apply(to: searchResults, settings: settings)
    }

    /// Scrolls to `id`. The very first call (the launch anchor restore) runs the hide-until-visible
    /// dance: `proxy.scrollTo` can only resolve a row the List has already laid out, and the launch
    /// request is delivered the same instant that row's data arrives, racing the List's own layout of
    /// it -- so this retries across a few short frames, exactly as `ManagedList.scrollToTargetIfNeeded`
    /// does, and keeps the rows hidden until the target is confirmed on screen so the user never sees
    /// the pre-scroll position. Every later call (Next/Previous Article, a remote anchor, the reanchor
    /// self-heal) takes the plain path: the sidebar is already visible by then, so a single scroll with
    /// no hiding is enough, matching how those callers already expect an immediate, visible jump.
    private func scrollToTarget(_ id: String, proxy: ScrollViewProxy) {
        guard !hasHandledFirstScrollRequest else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
            return
        }
        hasHandledFirstScrollRequest = true
        // "Revealed" only means "landed" when the reveal was still pending at request time. The
        // rows can legitimately be visible before the first request ever arrives -- a library that
        // was empty at launch and is filled by the first sync, or `scheduleRevealFallback` firing
        // on a slow cache load -- and in that case there is nothing to wait for, but every scroll
        // attempt below must still be made rather than skipped.
        let revealWasPending = !isRevealed
        Task { @MainActor in
            for delayMS in [0, 60, 250] {
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                if revealWasPending, isRevealed { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
                // Give the scroll one frame to take effect, so the position judged below is the
                // post-scroll one.
                try? await Task.sleep(nanoseconds: 16_000_000)
                scrollHasSettled = true
                if delayMS == 250 { isRevealed = true } else { revealIfTargetIsOnScreen() }
            }
        }
    }

    private func targetRowDidReport(_ frame: CGRect) {
        targetRowFrame = frame
        revealIfTargetIsOnScreen()
    }

    /// The reveal condition: the target row sits fully within the List's own bounds, i.e. the scroll
    /// really has put it on screen. Positions reported before the scroll settled don't count -- see
    /// `scrollHasSettled`.
    private func revealIfTargetIsOnScreen() {
        guard !isRevealed, scrollHasSettled, let frame = targetRowFrame else { return }
        isRevealed = ManagedListReveal.isRowFullyVisible(row: frame, inList: listFrame)
    }

    /// If the store has loaded and the library is empty, no scroll request will ever arrive (there
    /// is nothing to restore an anchor to), so hiding the rows forever would leave the sidebar
    /// permanently blank instead of showing its "No Articles" empty state.
    ///
    /// `store.hasLoaded` is the load-bearing half of that condition. This view appears *before*
    /// `ArticleStore` publishes anything -- `start()` runs from the scene's `.task`, and its first
    /// publish waits on the disk cache -- so on every launch the timeline is empty at `onAppear`.
    /// Judging "nothing to restore" from that emptiness alone revealed the rows right away, and the
    /// launch scroll that arrived with the index a moment later was then treated as already landed
    /// (see `scrollToTarget`): the reader opened on the anchored article while the sidebar sat at
    /// the top of the list. `store.summaries` rather than `model.filteredArticles` because the
    /// latter is derived by the parent's own `onChange` and may not have been recomputed yet when
    /// `hasLoaded` flips in the same update.
    private func revealIfNothingToRestore() {
        guard !isRevealed, !hasHandledFirstScrollRequest, store.hasLoaded, store.summaries.isEmpty else { return }
        isRevealed = true
    }

    /// Backstop for a launch anchor that, for whatever reason, never resolves to an on-screen row
    /// (e.g. the anchored article was deleted server-side between sessions) -- without this the
    /// sidebar would stay hidden indefinitely, which is a far worse failure than a brief top-of-list
    /// flash. `scrollToTarget`'s own 250ms-delay attempt already force-reveals on its own timeout;
    /// this is a second, independent safety net for the case where no scroll request arrives at all.
    private func scheduleRevealFallback() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !isRevealed { isRevealed = true }
        }
    }

    private func runSearch() async {
        let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = nil; return }
        searchResults = await ArticleSearch.searchSummaries(query: q, container: modelContext.container)
    }
}

/// The pinned tag/feed filter control at the top of the sidebar (the Mac home for what is a sheet on
/// iOS). A pull-down `Menu` of toggles that write straight to the shared `AppSettings` filter.
/// Reports the row's frame while `isTarget` is set, so `MacSidebarView` can reveal its rows the
/// moment the row it scrolled to is genuinely on screen. A copy of `ManagedList`'s private
/// `TargetRowPositionProbe`, kept separate rather than shared since that one is file-private to
/// `ManagedList.swift`. Written as a `ViewModifier` taking `isTarget` (not applied conditionally at
/// the call site) so a row's identity and its `List` metadata don't change when the flag flips.
private struct SidebarTargetRowProbe: ViewModifier {
    let isTarget: Bool
    let onPosition: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background {
            if isTarget {
                // A `GeometryReader`, not `onGeometryChange`, because the row may well be realized
                // already sitting in its final place: that produces no *change* to report, and the
                // reveal would be left waiting on the backstop. `onAppear` covers that first
                // position, `onChange` the ones the scroll produces.
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    Color.clear
                        .onAppear { onPosition(frame) }
                        .onChange(of: frame) { _, new in onPosition(new) }
                }
            }
        }
    }
}

/// Icon-only filter menu hosted in the sidebar's toolbar (`MacSidebarView.sidebarToolbar`).
private struct MacFilterMenu: View {
    let settings: AppSettings
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \Feed.name) private var feeds: [Feed]

    private var isFiltering: Bool { settings.isTimelineFilterActive }

    var body: some View {
        Menu {
            toggle(String(localized: "Starred Only"), isOn: settings.starredOnly) {
                settings.starredOnly = $0
            }
            // Three-way, unlike the toggles around it -- a `Picker` inside the menu renders as
            // a checkmarked group, which is the Mac convention for a radio-style choice.
            Picker(selection: Binding(
                get: { settings.readFilter },
                set: { settings.readFilter = $0 }
            )) {
                ForEach(ReadFilterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Text("Read State")
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
                    settings.readFilter = .all
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(isFiltering ? Color.accentColor : Color.primary)
        }
        .help(Text("Filter"))
        .accessibilityLabel(Text("Filter"))
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
                HStack(alignment: .top, spacing: 6) {
                    if !summary.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                            .accessibilityLabel(Text("Unread"))
                    }
                    Text(summary.title)
                        .font(.headline)
                        .foregroundStyle(titleColor)
                        .lineLimit(3)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if !summary.feedName.isEmpty {
                        Text(summary.feedName).fontWeight(.medium).foregroundStyle(feedNameColor)
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
        .background(hoverBackground)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
    }

    /// The feed name is accent-tinted, which is exactly the hue the selection pill is derived from —
    /// on the selected row it would disappear into its own background. Invert it there to the white
    /// the system already draws the rest of the selected row's text in.
    private var feedNameColor: Color { isSelected ? .white : Color.accentColor }

    /// Read titles recede like a mail client's; the selected row keeps the system's white text.
    private var titleColor: Color {
        if isSelected { return .white }
        return summary.isRead ? Color.secondary : Color.primary
    }

    @ViewBuilder private var hoverBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHovering && !isSelected ? Color.primary.opacity(0.06) : Color.clear)
            .padding(.horizontal, -6)
    }

    // Resolved lazily inside each action: `contextMenu` evaluates this builder at ROW-BODY
    // time for every visible row, so a SwiftData fetch or Keychain read here is paid per
    // scrolled row, not per right-click (audit finding). `model.hasServer`/`model.aiReady`
    // still call `AuthenticatedClient.current()` once each per row body, but that's cheap
    // after Task 1's Keychain caching; the `resolve(summary)` fetch and the per-article
    // gating that used to run through `ReaderMenuBuilder.config` now only happen on click.
    @ViewBuilder private var contextMenuItems: some View {
        let hasServer = model.hasServer

        Button {
            if let article = model.resolve(summary) { model.toggleStar(article) }
        } label: {
            Label(summary.isStarred ? "Unstar" : "Star",
                  systemImage: summary.isStarred ? "star.slash" : "star")
        }

        Button {
            if let article = model.resolve(summary) { model.toggleRead(article) }
        } label: {
            Label(summary.isRead ? "Mark as Unread" : "Mark as Read",
                  systemImage: summary.isRead ? "circle.fill" : "circle")
        }

        // Dropped while unpaired/demo: there's no server to open/reload/copy a real link for.
        if hasServer {
            Button {
                if let article = model.resolve(summary) { model.openWebsite(article) }
            } label: { Label("Open in Browser", systemImage: "safari") }
            if let url = URL(string: summary.identifier), url.scheme == "http" || url.scheme == "https" {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Button {
                if let article = model.resolve(summary) { model.copyLink(article) }
            } label: { Label("Copy link", systemImage: "link") }
            Button {
                if let article = model.resolve(summary) { model.openOnServer(article) }
            } label: { Label("Open on Server", systemImage: "server.rack") }
            Divider()
            Button {
                if let article = model.resolve(summary) { model.forceUpdateArticle(article) }
            } label: { Label("Reload", systemImage: "arrow.trianglehead.2.clockwise") }
        } else {
            Button {
                if let article = model.resolve(summary) { model.copyLink(article) }
            } label: { Label("Copy link", systemImage: "link") }
        }

        if model.aiReady {
            Button {
                if let article = model.resolve(summary) { model.summarize(article) }
            } label: { Label("Summarize", systemImage: "sparkles") }
                .disabled(model.isSummarizing)
        }

        Divider()
        Button(role: .destructive) {
            model.summaryPendingDelete = summary
        } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Detail-pane state when the library is empty: a call to add the first feed (when a server is
/// already paired) or to pair a server in the first place (when it isn't — a bare "Add Feed" button
/// would otherwise open the feed-creation WebView against no server at all).
private struct MacEmptyLibraryView: View {
    let isPaired: Bool
    let onCreateFeed: () -> Void
    let onPairServer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Articles", systemImage: "tray")
        } description: {
            Text(isPaired
                 ? "Add a feed to start reading."
                 : "Pair a Yana Server with feeds and articles to start reading.")
        } actions: {
            if isPaired {
                Button("Add Feed", action: onCreateFeed).buttonStyle(.borderedProminent)
            } else {
                Button("Pair Server", action: onPairServer).buttonStyle(.borderedProminent)
            }
        }
    }
}
