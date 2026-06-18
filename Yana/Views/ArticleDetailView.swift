import SwiftUI

/// Read-only article screen shown when a search result is tapped. Renders via the shared themed
/// web view (same HTML + native-browser links as the reader), but with no paging, no full-screen,
/// and standard insets (it sits inside a normal NavigationStack bar).
struct ArticleDetailView: View {
    let article: Article

    var body: some View {
        ReaderDetailWebView(article: article)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(article.feed?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// `UIViewControllerRepresentable` wrapper around `ReaderWebViewController` for the config-hub
/// search detail: themed HTML rendering with no paging/fullscreen controls.
private struct ReaderDetailWebView: UIViewControllerRepresentable {
    let article: Article

    func makeUIViewController(context: Context) -> ReaderWebViewController {
        ReaderWebViewController(article: article, allowsFullscreen: false, onRefresh: nil, onRequestShowBars: {})
    }

    func updateUIViewController(_ uiViewController: ReaderWebViewController, context: Context) {}
}
