import SwiftUI

/// The scrollable article body (title, meta line, rendered HTML) plus a bottom bar with
/// open-in-browser and share. Shared by the swipe reader and the search detail screen.
struct ArticleContentView: View {
    let article: Article
    @Environment(\.openURL) private var openURL
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    var body: some View {
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
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $isShowingShare) {
            if let url = shareURL { ShareSheet(activityItems: [url]) }
        }
    }

    private var bottomBar: some View {
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
}
