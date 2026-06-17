import SwiftUI

/// The full-page article web view (title, meta line, rendered HTML — all one scrolling,
/// zoomable web document) plus a bottom bar with open-in-browser and share. Shared by the
/// swipe reader (with pull-to-refresh) and the search detail screen (without).
struct ArticleContentView: View {
    let article: Article
    /// Optional pull-to-refresh trigger, forwarded to the web view. `nil` disables it.
    var onRefresh: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    var body: some View {
        ArticleWebView(article: article, onRefresh: onRefresh)
            .overlay(alignment: .bottom) { bottomBar }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
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
            .buttonStyle(.glass)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
