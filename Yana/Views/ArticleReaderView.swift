import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @State private var dragOffset: CGFloat = 0
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                if appState.isLoading && appState.articles.isEmpty {
                    ProgressView("Loading articles…")
                } else if let article = appState.currentArticle {
                    articleContent(article)
                        .offset(x: dragOffset)
                        .gesture(swipeGesture)
                        .animation(.interactiveSpring, value: dragOffset)
                } else if let error = appState.errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await appState.loadArticles() }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("All Caught Up", systemImage: "checkmark.circle")
                    } description: {
                        Text("No unread articles.")
                    } actions: {
                        Button("Refresh") {
                            Task { await appState.loadArticles() }
                        }
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
            .task {
                if appState.articles.isEmpty && appState.isAuthenticated {
                    await appState.loadArticles()
                }
            }
        }
    }

    // MARK: - Article Content

    @ViewBuilder
    private func articleContent(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Title
                Text(article.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                // Metadata row
                HStack(spacing: 8) {
                    if !article.feedTitle.isEmpty {
                        Text(article.feedTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    if !article.author.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(article.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(article.published, style: .relative)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Article HTML content
                ArticleWebView(htmlContent: article.content)
                    .frame(minHeight: 400)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(article)
        }
    }

    // MARK: - Bottom Bar

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
                    // Swipe left: mark as read and next
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = -UIScreen.main.bounds.width
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        await appState.markCurrentAsReadAndAdvance()
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold && appState.hasPreviousArticle {
                    // Swipe right: previous article
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = UIScreen.main.bounds.width
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.goToPreviousArticle()
                        dragOffset = 0
                    }
                } else {
                    // Snap back
                    withAnimation(.interactiveSpring) {
                        dragOffset = 0
                    }
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

