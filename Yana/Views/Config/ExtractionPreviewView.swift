import SwiftUI
import UIKit

/// Live preview of the full-website extraction: fetches the first few articles with the feed's
/// current selectors, renders each through the same `[Block]` pipeline the reader uses, and lets
/// the user switch between them with a top tab bar. A toolbar reload re-runs the extraction so
/// selector edits can be checked immediately.
struct ExtractionPreviewView: View {
    let identifier: String
    let options: AggregatorOptions

    /// Number of articles previewed.
    private static let previewCount = 3

    @State private var settings = AppSettings()
    @State private var state: LoadState = .loading
    @State private var selection = 0

    private enum LoadState {
        case loading
        case loaded([ReaderArticle])
        case failed(String)
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Fetching articles…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "eye.slash")
                } description: {
                    Text(message)
                }
            case .loaded(let articles):
                if articles.isEmpty {
                    ContentUnavailableView("No Articles",
                                           systemImage: "doc.text.magnifyingglass",
                                           description: Text("The feed returned no articles to preview."))
                } else {
                    loaded(articles)
                }
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading)
            }
        }
        .task { if case .loading = state { await load() } }
    }

    @ViewBuilder
    private func loaded(_ articles: [ReaderArticle]) -> some View {
        VStack(spacing: 0) {
            if articles.count > 1 {
                Picker("Article", selection: $selection) {
                    ForEach(articles.indices, id: \.self) { i in
                        Text("\(i + 1)").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            ArticleBlockView(
                article: articles[min(selection, articles.count - 1)],
                textSize: settings.articleTextSize,
                font: settings.articleFont,
                onOpenLink: { url in UIApplication.shared.open(url) }
            )
        }
    }

    private func reload() {
        state = .loading
        Task { await load() }
    }

    private func load() async {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            state = .failed(String(localized: "Enter a feed or website URL first."))
            return
        }
        let config = FeedConfig(type: .fullWebsite, identifier: trimmed,
                                dailyLimit: Self.previewCount, options: options, collectedToday: 0)
        guard let aggregator = AggregatorRegistry.shared.makeAggregator(config, credentials: AggregatorCredentials()) else {
            state = .failed(String(localized: "Couldn’t build the aggregator for this feed."))
            return
        }
        do {
            let aggregated = try await aggregator.aggregate()
            let articles = aggregated.prefix(Self.previewCount).map { article in
                ReaderArticle(
                    title: article.title,
                    author: article.author,
                    date: article.date,
                    url: article.url,
                    blocks: BlockParser.blocks(fromHTML: article.content, baseURL: URL(string: article.url))
                )
            }
            selection = 0
            state = .loaded(articles)
        } catch {
            state = .failed(String(localized: "Couldn’t fetch the articles. Check the URL and your connection."))
        }
    }
}
