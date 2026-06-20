import Foundation
import UIKit
import WebKit
import Testing
@testable import Yana

/// Runtime check of whether the reader's custom `yana-img://` image scheme actually loads in a
/// `WKWebView` — and specifically whether it survives the document's base origin. The reader loads
/// article HTML via `loadHTMLString(_:baseURL:)`; the base URL governs the document's security
/// origin, which decides whether custom-scheme subresources are allowed or blocked as insecure.
@MainActor
@Suite("ReaderImageScheme")
struct ReaderImageSchemeTests {
    private final class NavDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(); onFinish = nil }
    }

    /// Stores a real PNG in a temp `ImageStore`, renders an `<img>` referencing it under the given
    /// base URL, and returns the image's `naturalWidth` once loaded (0 = blocked/failed to load).
    private func loadedImageWidth(baseURL: URL?) async throws -> Int {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in }.pngData()!
        let store = ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
        let hash = try #require(await store.store(remoteURL: URL(string: "https://example.com/x.png")!,
                                                  isHeader: false))

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(store: store), forURLScheme: ReaderWeb.imageScheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        let delegate = NavDelegate()
        webView.navigationDelegate = delegate

        let html = "<html><body><img id=\"probe\" src=\"\(ReaderWeb.imageScheme)://\(hash)\"></body></html>"
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { cont.resume() }
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        // The image is a subresource: it loads asynchronously after `didFinish`. Poll briefly.
        for _ in 0..<40 {
            let width = (try? await webView.evaluateJavaScript(
                "document.getElementById('probe').naturalWidth")) as? Int ?? 0
            if width > 0 { return width }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return 0
    }

    /// Baseline: under a `file://` base origin the custom-scheme image loads.
    @Test func customSchemeImageLoadsUnderFileBase() async throws {
        let width = try await loadedImageWidth(baseURL: FileManager.default.temporaryDirectory)
        #expect(width > 0, "yana-img:// image must load under a file:// base origin")
    }

    /// Regression: under the reader's real `https://app.yana.local` base origin the same image must
    /// also load. If WebKit blocks the custom scheme as insecure mixed content here, every locally
    /// cached image (headers, inline, avatars, video posters) goes blank in the reader.
    @Test func customSchemeImageLoadsUnderReaderHTTPSBase() async throws {
        let width = try await loadedImageWidth(baseURL: ReaderWeb.pageBaseURL)
        #expect(width > 0, "yana-img:// image must load under the reader's https base origin")
    }

    /// End-to-end: a real `Article` rendered through `ArticleRenderer` with the current theme + page
    /// template, loaded exactly as the reader loads it. The content image must both *load*
    /// (naturalWidth) and *display* (non-zero rendered width — a theme rule could hide it).
    @Test func articleContentImageDisplaysThroughFullRenderer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in }.pngData()!
        let store = ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
        let hash = try #require(await store.store(remoteURL: URL(string: "https://example.com/x.png")!,
                                                  isHeader: false))

        let article = Article(
            title: "Example", identifier: "id", url: "https://example.com/a",
            content: "<section data-sanitized-class=\"article-content\"><p>"
                + "<img id=\"probe\" src=\"\(ReaderWeb.imageScheme)://\(hash)\"></p></section>")
        let html = ArticleRenderer.fullPageHTML(article: article,
                                                theme: ArticleThemesManager.shared.currentTheme,
                                                textSize: .medium)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(store: store), forURLScheme: ReaderWeb.imageScheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        let delegate = NavDelegate()
        webView.navigationDelegate = delegate
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { cont.resume() }
            webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
        }
        var natural = 0, rendered = 0.0
        for _ in 0..<40 {
            natural = (try? await webView.evaluateJavaScript(
                "document.getElementById('probe').naturalWidth")) as? Int ?? 0
            rendered = (try? await webView.evaluateJavaScript(
                "document.getElementById('probe').getBoundingClientRect().width")) as? Double ?? 0
            if natural > 0 && rendered > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(natural > 0, "content image must load through the full renderer")
        #expect(rendered > 0, "content image must be displayed (not hidden by theme CSS)")
    }
}
