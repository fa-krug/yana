import SwiftUI

/// The full-page article web view (title, meta line, rendered HTML — all one scrolling,
/// zoomable web document) plus a bottom bar with open-in-browser and share. Shared by the
/// swipe reader (with pull-to-refresh) and the search detail screen (without).
struct ArticleContentView: View {
    let article: Article
    /// Optional pull-to-refresh trigger, forwarded to the web view. `nil` disables it.
    var onRefresh: (() -> Void)?
    /// Real safe-area insets from the reader (including the navigation bar). Used only when
    /// `fullBleed` is true, to inset the article clear of the floating bars.
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    /// When true (the swipe reader), the article draws edge-to-edge under the floating bars
    /// and is content-inset to clear them. False (the search detail) keeps standard insets.
    var fullBleed: Bool = false

    @Environment(\.openURL) private var openURL
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    /// Height reserved for the floating bottom action bar so the last line clears it.
    /// Sized for the enlarged (NetNewsWire-scale) glass icons below.
    private let actionBarHeight: CGFloat = 76

    var body: some View {
        ArticleWebView(article: article, onRefresh: onRefresh, readerContentInset: readerContentInset)
            // Full-bleed: pin the web view to the screen edges (like NetNewsWire, which
            // constrains its web view to the view's own anchors). Without this the hosting
            // controller insets the view by the safe area, and the bottom bar's
            // `safeAreaInsets.bottom` padding below would then double-count that inset —
            // lifting the floating bar far too high above the home indicator.
            .ignoresSafeArea(edges: fullBleed ? .all : [])
            .overlay(alignment: .bottom) {
                bottomBar.padding(.bottom, fullBleed ? safeAreaInsets.bottom : 0)
            }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
    }

    /// Explicit content inset for the full-bleed reader: clears the navigation bar at the top
    /// and the home indicator plus the floating action bar at the bottom. `nil` outside the
    /// reader so the web view keeps its automatic inset adjustment.
    private var readerContentInset: UIEdgeInsets? {
        guard fullBleed else { return nil }
        return UIEdgeInsets(
            top: safeAreaInsets.top,
            left: 0,
            bottom: safeAreaInsets.bottom + actionBarHeight,
            right: 0
        )
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
            .font(.title2)
            .buttonStyle(.glass)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
