import Foundation
import CryptoKit
import SwiftSoup

/// Downloads, compresses, and caches images as files keyed by content hash.
/// Article HTML references them via `yana-img://<hash>` (no remote URLs reach the WebView).
actor ImageStore {
    private let directory: URL
    private let fetch: @Sendable (URL) async throws -> (Data, String?)
    private var extensions: [String: String] = [:]   // hash -> file extension

    init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> (Data, String?) = { try await HTTPClient.fetchData($0) }) {
        self.directory = directory
        self.fetch = fetch
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let shared: ImageStore = {
        let dir = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("images") ?? FileManager.default.temporaryDirectory.appendingPathComponent("images")
        return ImageStore(directory: dir)
    }()

    /// Returns the content hash for a downloaded+compressed image, or nil on failure.
    func store(remoteURL: URL, isHeader: Bool) async -> String? {
        guard let (data, contentType) = try? await fetch(remoteURL),
              let compressed = ImageCompressor.compress(data, contentType: contentType, isHeader: isHeader) else { return nil }
        let hash = Self.hash(compressed.data)
        extensions[hash] = compressed.ext
        let url = fileURL(forHash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try compressed.data.write(to: url) } catch { return nil }
        }
        return hash
    }

    func fileURL(forHash hash: String) -> URL {
        if let ext = extensions[hash] {
            return directory.appendingPathComponent("\(hash).\(ext)")
        }
        // Cross-launch fallback: the in-memory map is empty on a fresh launch, so locate the
        // already-cached file on disk by its hash stem.
        if let match = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.deletingPathExtension().lastPathComponent == hash }) {
            return match
        }
        return directory.appendingPathComponent("\(hash).img")
    }

    func purgeOrphans(keepingHashes: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if !keepingHashes.contains(name) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Walks every `<img>`, downloads via the store, and rewrites `src` to `yana-img://<hash>`.
/// Unresolved images are dropped (spec decision 3: no remote image URLs).
func rewriteImages(in doc: Document, store: ImageStore, baseURL: URL?) async throws {
    for img in try doc.select("img") {
        let raw = try [ "src", "data-src", "data-lazy-src" ].lazy
            .map { try img.attr($0) }.first { !$0.isEmpty } ?? ""
        guard !raw.isEmpty, !raw.hasPrefix("data:") else { try img.remove(); continue }
        let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL
        guard let resolved else { try img.remove(); continue }
        if let hash = await store.store(remoteURL: resolved, isHeader: false) {
            try img.attr("src", "\(ReaderWeb.imageScheme)://\(hash)")
            try img.removeAttr("data-src"); try img.removeAttr("data-lazy-src"); try img.removeAttr("srcset")
        } else {
            try img.remove()
        }
    }
}
