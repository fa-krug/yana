import Foundation
import CryptoKit

/// Disk cache of images keyed by content hash, fetched from the server on cache miss.
/// Article/feed-logo references use `yana-img://<hash>` (the server delivers the ref directly in
/// `WireBlock.image`/`Feed.logoImageHash`; there is no remote-URL resolution, compression,
/// background removal, or HTML rewriting client-side any more -- the server already delivers
/// final processed bytes).
actor ImageStore {
    private let directory: URL
    private var extensions: [String: String] = [:]   // hash -> file extension

    /// The response cap and accept header carried over from the old on-device-scraping
    /// `HTTPClient` -- raised specifically for large Reddit GIFs. The server doesn't enforce an
    /// equivalent cap itself, so this stays a client-side protection.
    static let maxImageResponseBytes = 64 * 1024 * 1024
    static let imageAccept = "image/*,*/*;q=0.8"

    init(directory: URL) {
        self.directory = directory
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

    /// Fetches `GET /api/v1/images/:hash` on cache miss and writes the raw bytes verbatim under
    /// that exact hash -- no recompression, no re-hashing (the server already stores final
    /// processed bytes for both article images and feed logos; the hash is the server's own
    /// identity, not locally computed as it was before). Returns whether bytes are on disk
    /// afterward.
    func fetchIfNeeded(hash: String, client: YanaAPIClient) async -> Bool {
        if fileExists(forHash: hash) { return true }
        guard let (data, response) = try? await client.getRaw("/api/v1/images/\(hash)"),
              (200..<300).contains(response.statusCode),
              data.count <= Self.maxImageResponseBytes else {
            return false
        }
        let ext = Self.fileExtension(forContentType: response.value(forHTTPHeaderField: "Content-Type"))
        extensions[hash] = ext
        let url = fileURL(forHash: hash)
        try? data.write(to: url)
        return true
    }

    /// Stores already-decoded local image bytes (no fetch) under a content hash, recording `ext`
    /// so `fileURL(forHash:)` resolves the right file. Used by DEBUG screenshot/test fixtures;
    /// `ext` is a bare extension, e.g. "jpg".
    func storeData(_ data: Data, ext: String) -> String {
        let hash = Self.hash(data)
        extensions[hash] = ext
        let url = fileURL(forHash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return hash
    }

    func fileURL(forHash hash: String) -> URL {
        directory.appendingPathComponent(hash).appendingPathExtension(extensions[hash] ?? "img")
    }

    /// Whether a blob for this hash already exists on disk.
    func fileExists(forHash hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forHash: hash).path)
    }

    /// Raw bytes for a stored hash, or nil when absent.
    func rawData(forHash hash: String) -> Data? {
        try? Data(contentsOf: fileURL(forHash: hash))
    }

    /// The recorded file extension for a hash (defaults to "img" when unknown).
    func recordedExt(forHash hash: String) -> String { extensions[hash] ?? "img" }

    /// Every content hash currently cached on disk (from the seeded extension map).
    func allHashes() -> Set<String> { Set(extensions.keys) }

    /// Deletes the on-disk blob for `hash`, if any, and drops it from the extension map so a
    /// later `fileURL(forHash:)` doesn't resolve a stale extension.
    func remove(forHash hash: String) {
        try? FileManager.default.removeItem(at: fileURL(forHash: hash))
        extensions.removeValue(forKey: hash)
    }

    private static func fileExtension(forContentType contentType: String?) -> String {
        switch contentType?.split(separator: ";").first.map(String.init) {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "img"
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    nonisolated static func hashForTesting(_ data: Data) -> String { hash(data) }
    #endif
}
