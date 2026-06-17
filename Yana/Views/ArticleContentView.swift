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

    @State private var shareURL: URL?
    @State private var isShowingShare = false
    /// A link tapped inside the article body, presented in its own webview sheet.
    @State private var linkURL: IdentifiedURL?

    /// Height reserved for the floating bottom action bar so the last line clears it.
    /// Sized for the enlarged (NetNewsWire-scale) glass icons below.
    private let actionBarHeight: CGFloat = 76

    /// Gap between the floating bar and the screen's bottom edge. Small enough that the bar
    /// rests just over the home indicator margin instead of a full safe-area inset above it.
    private let bottomBarGap: CGFloat = 8

    var body: some View {
        ArticleWebView(
            article: article,
            onRefresh: onRefresh,
            onOpenLink: { linkURL = IdentifiedURL(url: $0) },
            readerContentInset: readerContentInset
        )
            // Full-bleed: pin the web view to the screen edges (like NetNewsWire, which
            // constrains its web view to the view's own anchors). Without this the hosting
            // controller insets the view by the safe area, and the bottom bar's
            // `safeAreaInsets.bottom` padding below would then double-count that inset —
            // lifting the floating bar far too high above the home indicator.
            .ignoresSafeArea(edges: fullBleed ? .all : [])
            .overlay(alignment: .bottom) {
                // Sit just above the home indicator rather than a full inset above it: the glass
                // capsule may overlap the indicator margin, so only a small gap is reserved.
                bottomBar.padding(.bottom, fullBleed ? bottomBarGap : 0)
            }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
            .sheet(item: $linkURL) { LinkSheet(url: $0.url) }
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
                    Button { linkURL = IdentifiedURL(url: url) } label: {
                        Label("Open Page", systemImage: "globe")
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
