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
        // Seed the hash -> ext map from existing files so cross-launch lookups are O(1),
        // not a directory scan per image reference.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                let stem = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension
                if !stem.isEmpty, !ext.isEmpty { extensions[stem] = ext }
            }
        }
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

/// Picks the highest-resolution URL from a srcset value (largest `w` descriptor, else
/// largest `x` descriptor, else the first candidate). Returns nil if none parse.
/// Ignores empty or `data:` candidate URLs.
///
/// Implementation detail of `rewriteImages` — kept `internal` (not `private`) so that
/// `@testable import Yana` can access it from unit tests.
func largestSrcsetURL(_ srcset: String) -> String? {
    // Split on commas — each part is one candidate
    let candidates = srcset.split(separator: ",", omittingEmptySubsequences: true)
        .compactMap { part -> (url: String, w: Double?, x: Double?)? in
            let tokens = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let url = tokens.first, !url.isEmpty, !url.hasPrefix("data:") else { return nil }
            let descriptor = tokens.dropFirst().first ?? ""
            var w: Double? = nil
            var x: Double? = nil
            if descriptor.hasSuffix("w"), let v = Double(descriptor.dropLast()) { w = v }
            else if descriptor.hasSuffix("x"), let v = Double(descriptor.dropLast()) { x = v }
            return (url: url, w: w, x: x)
        }
    guard !candidates.isEmpty else { return nil }
    // Prefer largest w descriptor
    let wCandidates = candidates.filter { $0.w != nil }
    if !wCandidates.isEmpty {
        return wCandidates.max(by: { $0.w! < $1.w! })?.url
    }
    // Fall back to largest x descriptor
    let xCandidates = candidates.filter { $0.x != nil }
    if !xCandidates.isEmpty {
        return xCandidates.max(by: { $0.x! < $1.x! })?.url
    }
    // No descriptors — return first candidate
    return candidates.first?.url
}

/// Walks every `<img>`, downloads via the store, and rewrites `src` to `yana-img://<hash>`.
/// Unresolved images are dropped (spec decision 3: no remote image URLs).
/// When `src`/`data-src`/`data-lazy-src` are absent or a `data:` placeholder, falls back
/// to the best candidate from the `srcset` attribute.
func rewriteImages(in doc: Document, store: ImageStore, baseURL: URL?) async throws {
    for img in try doc.select("img") {
        var raw = try [ "src", "data-src", "data-lazy-src" ].lazy
            .map { try img.attr($0) }.first { !$0.isEmpty } ?? ""
        if raw.isEmpty || raw.hasPrefix("data:") {
            raw = largestSrcsetURL(try img.attr("srcset")) ?? ""
        }
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
