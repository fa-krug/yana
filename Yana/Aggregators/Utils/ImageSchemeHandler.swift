import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves `yana-img://<hash>` requests from the local image cache.
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: ImageStore

    init(store: ImageStore = .shared) { self.store = store }

    static func hash(from url: URL) -> String? {
        // yana-img://<hash> → host is the hash
        url.host ?? (url.absoluteString.components(separatedBy: "://").last)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let hash = Self.hash(from: url) else {
            task.didFailWithError(URLError(.badURL)); return
        }
        Task {
            let fileURL = await store.fileURL(forHash: hash)
            guard let data = try? Data(contentsOf: fileURL) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let ext = fileURL.pathExtension
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/jpeg"
            let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
            task.didReceive(response); task.didReceive(data); task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
