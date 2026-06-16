import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var didRestoreAnchor = false

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
                    ArticlePagerView(
                        articles: articles,
                        currentIndex: $appState.currentIndex,
                        onRefresh: { await refresh() }
                    )
                    .ignoresSafeArea(.container, edges: .horizontal)
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
            .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
            .sheet(isPresented: $appState.showFilter, onDismiss: clampIndex) { TagFilterView() }
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

    private func refresh() async {
        let service = AggregationService(context: modelContext)
        await service.updateAll()
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
