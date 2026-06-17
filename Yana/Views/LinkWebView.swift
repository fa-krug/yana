import SwiftUI
import WebKit

/// Wraps a `URL` so it can drive a `.sheet(item:)`. The URL string is a stable identity, so
/// tapping a different link re-presents the sheet with the new page.
struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A bare `WKWebView` that loads a single remote URL — the live web page, not Yana's
/// reader-formatted article. Used by `LinkSheet` to show links tapped inside an article.
struct LinkWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var loadedURL: URL?
    }

    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }
}

/// Presents a tapped link in its own sheet: a navigation stack wrapping `LinkWebView` with a
/// Done button plus open-in-browser and share actions, so links opened from the reader stay
/// inside the app instead of bouncing out to Safari.
struct LinkSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isShowingShare = false

    var body: some View {
        NavigationStack {
            LinkWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.host() ?? url.absoluteString)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Done", systemImage: "xmark")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        Button {
                            isShowingShare = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .sheet(isPresented: $isShowingShare) {
                    ShareSheet(activityItems: [url])
                }
        }
    }
}
