import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var dragOffset: CGFloat = 0
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    /// The timeline after applying the persisted tag filter.
    private var articles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }

    private var currentArticle: Article? {
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return nil }
        return articles[appState.currentIndex]
    }

    private var starredTag: Tag? { builtInTags.first }

    var body: some View {
        NavigationStack {
            ZStack {
                if let article = currentArticle {
                    articleContent(article)
                        .offset(x: dragOffset)
                        .gesture(swipeGesture)
                        .animation(.interactiveSpring, value: dragOffset)
                } else {
                    ContentUnavailableView {
                        Label("No Articles", systemImage: "tray")
                    } description: {
                        Text("Add feeds in Configuration, then pull down to refresh.")
                    }
                }
            }
            .refreshable { await refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { appState.showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let article = currentArticle, let starredTag {
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
            .sheet(isPresented: $appState.showFilter) { TagFilterView() }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
            .onAppear { restoreAnchor() }
            .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
        }
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
    }

    private func saveAnchor() {
        settings.timelineAnchorIdentifier = currentArticle?.identifier
    }

    // MARK: - Refresh (current article + whole timeline)

    private func refresh() async {
        let service = AggregationService(context: modelContext)
        if let article = currentArticle { await service.update(article: article) }
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
                Button { UIApplication.shared.open(url) } label: {
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

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in dragOffset = value.translation.width }
            .onEnded { value in
                let threshold: CGFloat = 100
                if value.translation.width < -threshold, appState.currentIndex < articles.count - 1 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = -UIScreen.main.bounds.width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex += 1
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold, appState.currentIndex > 0 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = UIScreen.main.bounds.width }
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
