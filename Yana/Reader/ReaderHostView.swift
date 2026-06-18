import SwiftData
import SwiftUI
import UIKit

/// Bridges the UIKit reader into SwiftUI: feeds the filtered timeline + selected index down to
/// `ReaderArticleViewController` and reports index changes back up. The chrome buttons call back
/// into SwiftUI for the Filter/Settings sheets and starring.
struct ReaderHostView: UIViewControllerRepresentable {
    let articles: [Article]
    @Binding var currentIndex: Int
    let isRefreshing: Bool
    let isFilterActive: Bool
    var onRefresh: (() -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?

    func makeUIViewController(context: Context) -> UINavigationController {
        let reader = ReaderArticleViewController()
        context.coordinator.reader = reader
        reader.onIndexChange = { currentIndex = $0 }
        reader.onShowFilter = onShowFilter
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.configure(articles: articles, index: currentIndex)
        reader.setRefreshing(isRefreshing)
        reader.setFilterActive(isFilterActive)

        let nav = UINavigationController(rootViewController: reader)
        nav.isToolbarHidden = false
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        guard let reader = context.coordinator.reader else { return }
        reader.onIndexChange = { currentIndex = $0 }
        reader.onShowFilter = onShowFilter
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.update(articles: articles, index: currentIndex)
        reader.setRefreshing(isRefreshing)
        reader.setFilterActive(isFilterActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var reader: ReaderArticleViewController?
    }
}

/// The home surface: owns the timeline `@Query`, tag filter, position memory, refresh, and the
/// Settings/Filter sheets. Replaces the former `ArticleReaderView`.
struct ReaderScreen: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.createdAt, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var didRestoreAnchor = false
    @State private var statusMessage: String?

    private var filteredArticles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    var body: some View {
        let articles = filteredArticles
        Group {
            if articles.isEmpty {
                ContentUnavailableView {
                    Label("No Articles", systemImage: "tray")
                        .accessibilityIdentifier("emptyArticlesTitle")
                } description: {
                    Text("Add feeds in the Library, then pull down to refresh.")
                } actions: {
                    Button(String(localized: "Add Your First Feed")) { appState.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ReaderHostView(
                    articles: articles,
                    currentIndex: $appState.currentIndex,
                    isRefreshing: UpdateActivity.shared.isUpdating,
                    isFilterActive: settings.isTimelineFilterActive,
                    onRefresh: triggerRefresh,
                    onShowFilter: { appState.showFilter = true },
                    onShowSettings: { appState.showSettings = true },
                    onToggleStar: toggleStar
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
        .sheet(isPresented: $appState.showFilter, onDismiss: clampIndex) { TagFilterView() }
        .alert("Update Failed", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("Retry") { triggerRefresh() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.statusMessage = nil
                    }
            }
        }
        .animation(.snappy, value: statusMessage)
        .onAppear {
            restoreAnchor()
            if !settings.hasSeenFullscreenHint, UIDevice.current.userInterfaceIdiom == .phone {
                statusMessage = String(localized: "Tap the title bar to hide the toolbars.")
                settings.hasSeenFullscreenHint = true
            }
        }
        .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
        .onChange(of: allArticles) { _, _ in
            if didRestoreAnchor { clampIndex() } else { restoreAnchor() }
        }
    }

    private func toggleStar(_ article: Article) {
        guard let starredTag else { return }
        article.setStarred(!article.isStarred, using: starredTag)
        try? modelContext.save()
        Haptics.impact(.light)
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
        guard !articles.isEmpty else { return }
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return }
        settings.timelineAnchorIdentifier = articles[appState.currentIndex].identifier
    }

    private func clampIndex() {
        let clamped = min(appState.currentIndex, max(0, filteredArticles.count - 1))
        if clamped != appState.currentIndex {
            statusMessage = String(localized: "Showing the nearest article in this filter.")
        }
        appState.currentIndex = clamped
    }

    // MARK: - Refresh

    private func triggerRefresh() {
        // A fresh pull cancels any update already running and starts over, rather than no-op'ing.
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.updateAll()
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: nil)
                Haptics.impact(.light)
            }
        }
    }
}

/// Presents a `UIActivityViewController` from SwiftUI (used by the search detail + link sheets).
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
