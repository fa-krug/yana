import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var dragOffset: CGFloat = 0
    @State private var viewWidth: CGFloat = 0
    @State private var shareURL: URL?
    @State private var isShowingShare = false

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
                if let article = current {
                    articleContent(article)
                        .offset(x: dragOffset)
                        .gesture(swipeGesture(in: articles))
                        .animation(.interactiveSpring, value: dragOffset)
                } else {
                    ContentUnavailableView {
                        Label("No Articles", systemImage: "tray")
                    } description: {
                        Text("Add feeds in Configuration, then pull down to refresh.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                viewWidth = newWidth
            }
            .refreshable { await refresh(current: current) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { appState.showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let article = current, let starredTag {
                        Button {
                            article.setStarred(!article.isStarred, using: starredTag)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: article.isStarred ? "star.fill" : "star")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { appState.showSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
            .sheet(isPresented: $appState.showFilter, onDismiss: clampIndex) { TagFilterView() }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
            .onAppear { restoreAnchor() }
            .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
            .onChange(of: allArticles) { _, _ in clampIndex() }
        }
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: filteredArticles)
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

    // MARK: - Refresh (current article + whole timeline)

    private func refresh(current: Article?) async {
        let service = AggregationService(context: modelContext)
        if let current { await service.update(article: current) }
        await service.updateAll()
    }

    // MARK: - Article Content

    @ViewBuilder
    private func articleContent(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let feedTitle = article.feed?.name, !feedTitle.isEmpty {
                        Text(feedTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    if !article.author.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(article.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(article.date, style: .relative).font(.subheadline).foregroundStyle(.secondary)
                }

                Divider()

                ArticleWebView(htmlContent: article.content).frame(minHeight: 400)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { bottomBar(article) }
    }

    private func bottomBar(_ article: Article) -> some View {
        HStack {
            Spacer()
            if let url = URL(string: article.url) {
                Button { openURL(url) } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button { shareURL = url; isShowingShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Swipe Gesture (bidirectional, no read state)

    private func swipeGesture(in articles: [Article]) -> some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in dragOffset = value.translation.width }
            .onEnded { value in
                let threshold: CGFloat = 100
                if value.translation.width < -threshold, appState.currentIndex < articles.count - 1 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = -viewWidth }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex += 1
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold, appState.currentIndex > 0 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = viewWidth }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex -= 1
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.interactiveSpring) { dragOffset = 0 }
                }
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
