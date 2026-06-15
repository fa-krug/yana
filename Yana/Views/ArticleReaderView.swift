import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Query(
        filter: #Predicate<Article> { !$0.read },
        sort: \Article.date,
        order: .reverse
    ) private var articles: [Article]

    @State private var dragOffset: CGFloat = 0
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    private var currentArticle: Article? {
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else {
            return nil
        }
        return articles[appState.currentIndex]
    }

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
                        Label("All Caught Up", systemImage: "checkmark.circle")
                    } description: {
                        Text("No unread articles. Add feeds in Settings.")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $appState.showSettings) {
                SettingsView(appState: appState)
            }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
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
                        Text(article.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(article.date, style: .relative)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ArticleWebView(htmlContent: article.content)
                    .frame(minHeight: 400)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(article)
        }
    }

    private func bottomBar(_ article: Article) -> some View {
        HStack {
            Spacer()
            if let url = URL(string: article.url) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button {
                    shareURL = url
                    isShowingShare = true
                } label: {
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

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 100
                if value.translation.width < -threshold {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = -UIScreen.main.bounds.width
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        markCurrentAsReadAndAdvance()
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold && appState.currentIndex > 0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = UIScreen.main.bounds.width
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex -= 1
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.interactiveSpring) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// Mark the current article read. The `@Query` (unread-only) drops it, so the next
    /// unread article shifts into the current index automatically; clamp the index.
    private func markCurrentAsReadAndAdvance() {
        guard let article = currentArticle else { return }
        article.read = true
        if appState.currentIndex >= articles.count - 1 {
            appState.currentIndex = max(0, articles.count - 2)
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
