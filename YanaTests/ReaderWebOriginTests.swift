import Foundation
import Testing
import WebKit
@testable import Yana

/// Verifies the fix for YouTube "Error 153": the reader document must load at the same origin
/// (`ReaderWeb.baseOrigin`) that every embed declares in its `origin=` param, and the custom
/// `yana-img://` image scheme must still load under that `https` document (no mixed-content block).
@MainActor
struct ReaderWebOriginTests {

    /// The embed markup keeps declaring the app origin — the value the document must match.
    @Test func embedDeclaresAppOrigin() {
        let html = EmbedRewriter.youTubeEmbedHTML(videoID: "dQw4w9WgXcQ")
        #expect(html.contains("origin=\(ReaderWeb.baseOrigin)"))
        #expect(html.contains("youtube-nocookie.com/embed/dQw4w9WgXcQ"))
    }

    /// The load base URL is exactly the declared embed origin (the heart of the fix).
    @Test func pageBaseURLMatchesEmbedOrigin() {
        #expect(ReaderWeb.pageBaseURL.absoluteString == ReaderWeb.baseOrigin)
    }

    /// Loading article HTML at `pageBaseURL` gives the document the declared origin, and a
    /// `yana-img://` image still decodes under that `https` document.
    @Test func documentOriginMatchesAndImageLoads() async throws {
        // Seed an image store with a real 1x1 PNG under a known hash.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("readerweb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = "testimagehash"
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAen63NgAAAAASUVORK5CYII="
        try Data(base64Encoded: pngBase64)!.write(to: dir.appendingPathComponent("\(hash).png"))
        let store = ImageStore(directory: dir)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(store: store), forURLScheme: ReaderWeb.imageScheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), configuration: config)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate

        let html = """
        <html><head><base href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"></head>
        <body><img src="\(ReaderWeb.imageScheme)://\(hash)"></body></html>
        """
        webView.loadHTMLString(html, baseURL: ReaderWeb.pageBaseURL)
        try await delegate.waitForLoad()

        // 1. The document's real origin matches the origin every embed declares.
        let origin = try await webView.evalString("location.origin")
        #expect(origin == ReaderWeb.baseOrigin)

        // 2. The yana-img image decoded under the https document (not mixed-content blocked).
        //    Image subresource loading completes asynchronously after the document; poll briefly.
        var naturalWidth = 0
        for _ in 0..<40 {
            let w = try await webView.evalString(
                "(function(){var i=document.images[0];return ''+(i&&i.complete?i.naturalWidth:0);})()")
            if let w, let parsed = Int(w), parsed > 0 { naturalWidth = parsed; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(naturalWidth > 0)
    }
}

/// Resumes once the WebView finishes (or fails) the initial document load.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func waitForLoad() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(.failure(error)) }
    private func resume(_ result: Result<Void, Error>) {
        finished = true
        continuation?.resume(with: result); continuation = nil
    }
}

private extension WKWebView {
    /// Evaluates `script` and returns its result as a `String` (the only `Sendable` shape we need),
    /// casting inside the completion so no non-`Sendable` `Any?` crosses the continuation boundary.
    func evalString(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            evaluateJavaScript(script) { value, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: value as? String) }
            }
        }
    }
}
