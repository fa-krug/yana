import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var didRestoreAnchor = false
    @State private var isRefreshing = false

    /// The timeline after applying the persisted tag filter. Recomputed on demand; the
    /// `body` evaluates it once per render and threads the result through helpers so
    /// `TagFilter.apply` does not re-run on every access during a swipe.
    private var filteredArticles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }

    private func currentArticle(in articles: [Article]) -> Article? {
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return nil }
        return articles[appState.currentIndex]
    }

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    var body: some View {
        let articles = filteredArticles
        let current = currentArticle(in: articles)
        NavigationStack {
            ZStack {
                if current != nil {
                    // Capture the real safe-area insets (incl. the navigation bar) before the
                    // pager draws full-bleed, so each article clears the floating bars.
                    GeometryReader { proxy in
                        ArticlePagerView(
                            articles: articles,
                            currentIndex: $appState.currentIndex,
                            onRefresh: triggerRefresh,
                            safeAreaInsets: proxy.safeAreaInsets
                        )
                        .ignoresSafeArea()
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Articles", systemImage: "tray")
                            .accessibilityIdentifier("emptyArticlesTitle")
                    } description: {
                        Text("Add feeds in Configuration, then pull down to refresh.")
                    } actions: {
                        Button(String(localized: "Add Your First Feed")) {
                            appState.showSettings = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                        .padding(.top, 8)
                        .accessibilityLabel(String(localized: "Refreshing feeds"))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: isRefreshing)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { appState.showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .accessibilityLabel(String(localized: "Filter articles"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let article = current, let starredTag {
                        Button {
                            article.setStarred(!article.isStarred, using: starredTag)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: article.isStarred ? "star.fill" : "star")
                        }
                        .accessibilityLabel(article.isStarred ? String(localized: "Unstar article") : String(localized: "Star article"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { appState.showSettings = true } label: { Image(systemName: "gear") }
                        .accessibilityLabel(String(localized: "Settings"))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
            .sheet(isPresented: $appState.showFilter, onDismiss: clampIndex) { TagFilterView() }
            .alert("Update Failed", isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.errorMessage ?? "")
            }
            .onAppear { restoreAnchor() }
            .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
            .onChange(of: allArticles) { _, _ in
                if didRestoreAnchor {
                    clampIndex()
                } else {
                    restoreAnchor()
                }
            }
        }
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        let articles = filteredArticles
        guard !articles.isEmpty, !didRestoreAnchor else { return }
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
        didRestoreAnchor = true
    }

    private func saveAnchor() {
        let articles = filteredArticles
        // Skip while the timeline is empty (e.g. the @Query has not delivered yet) so a
        // transient nil does not erase a previously persisted position.
        guard !articles.isEmpty else { return }
        settings.timelineAnchorIdentifier = currentArticle(in: articles)?.identifier
    }

    /// Keeps `currentIndex` within bounds after the filtered list shrinks — e.g. when the
    /// user disables tags in the filter sheet or articles are removed.
    private func clampIndex() {
        appState.currentIndex = min(appState.currentIndex, max(0, filteredArticles.count - 1))
    }

    // MARK: - Refresh (whole timeline)

    /// Kicks off an all-feeds update without blocking the pull gesture. The refresh control
    /// retracts immediately; progress is shown through the reader's loading indicator instead.
    /// Ignores re-triggers while an update is already running.
    private func triggerRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let service = AggregationService(context: modelContext)
            await service.updateAll()
            appState.errorMessage = SyncFailureSummary.message(for: service.lastRunFailures)
            isRefreshing = false
        }
    }

}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
