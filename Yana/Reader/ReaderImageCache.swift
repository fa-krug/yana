import UIKit
import ImageIO

/// In-memory cache of decoded reader images, keyed by their `yana-img://<hash>` (or remote URL)
/// ref. Exists so a page that has already been seen — or whose lead image was preloaded ahead of a
/// swipe — renders its image *synchronously* on the first body evaluation instead of starting from
/// an empty placeholder and popping in after an async disk read.
///
/// `ReaderImageView` reads `cached(_:)` synchronously when it builds; the pager calls `preload(_:)`
/// for the lead images of the neighbors it prewarms, so by the time the user swipes to a page its
/// header image is already decoded in memory. `NSCache` evicts under memory pressure on its own.
///
/// Not actor-isolated: `cached(_:)` has to be callable synchronously from a SwiftUI `View.init`
/// (a non-isolated context). Storage is an `NSCache` (thread-safe) and the in-flight table is
/// guarded by a lock, so the type is safe to touch from any thread.
final class ReaderImageCache: @unchecked Sendable {
    static let shared = ReaderImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    /// Refs with an in-flight load, so concurrent requests (e.g. the page rendering while a prewarm
    /// runs) share one disk read instead of decoding the same file twice.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Cap for the decoded in-memory copy. Reader images never render wider than the content column,
    /// so decoding to ~1600px (rather than the on-disk ≤2000px original) cuts decode time and memory
    /// while staying sharp at every iPhone content width and visually indistinguishable on iPad.
    /// A constant so it can be profiled and dialed on-device.
    private static let maxPixelSize = 1600

    init() {
        // Decoded reader images are large; bound the count so a long browsing session can't grow the
        // cache without limit. The pager only keeps a handful of pages alive, so a small window of
        // recently decoded images is plenty.
        cache.countLimit = 32
        // Also bound by decoded bytes — now that images are force-decoded into bitmaps (not held as
        // lazy file-backed images), a window of large headers could otherwise dominate memory.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    /// Synchronous lookup — returns the decoded image if it is already in memory, else nil.
    func cached(_ ref: String) -> UIImage? {
        cache.object(forKey: ref as NSString)
    }

    /// Returns the cached image, or loads it off the main thread, caches it, and returns it.
    /// Coalesces concurrent loads of the same ref onto one task.
    func image(for ref: String) async -> UIImage? {
        if let hit = cached(ref) { return hit }

        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[ref] { return existing }
            let task = Task { await Self.load(ref) }
            inFlight[ref] = task
            return task
        }

        let image = await task.value
        if let image { cache.setObject(image, forKey: ref as NSString, cost: Self.cost(of: image)) }
        lock.withLock { _ = inFlight.removeValue(forKey: ref) }
        return image
    }

    /// Fire-and-forget warming used by the pager's prewarm pass for neighbor lead images.
    func preload(_ ref: String) {
        guard cached(ref) == nil else { return }
        Task { _ = await image(for: ref) }
    }

    /// Reads and decodes the image for a `yana-img://<hash>` ref from the local `ImageStore`, or a
    /// remote URL fallback. Runs entirely off the main thread.
    private static func load(_ ref: String) async -> UIImage? {
        let prefix = "\(ReaderWeb.imageScheme)://"
        if ref.hasPrefix(prefix) {
            let hash = String(ref.dropFirst(prefix.count))
            let url = await ImageStore.shared.fileURL(forHash: hash)
            return await Task.detached { decodedImage(at: url) }.value
        }
        guard let url = URL(string: ref) else { return nil }
        return await Task.detached {
            (try? Data(contentsOf: url)).flatMap { decodedImage(from: $0) }
        }.value
    }

    /// Decodes (and downsamples) the image at `url` into a draw-ready bitmap, fully realized on the
    /// calling background thread so the first on-screen draw doesn't pay a synchronous decode — the
    /// hitch behind the image "pop-in". Falls back to a plain file load if ImageIO can't open it.
    private static func decodedImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return UIImage(contentsOfFile: url.path)
        }
        return decodedImage(from: source) ?? UIImage(contentsOfFile: url.path)
    }

    private static func decodedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        return decodedImage(from: source) ?? UIImage(data: data)
    }

    private static func decodedImage(from source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            // Decode the bitmap now, on this background thread, instead of lazily on first draw.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,  // never upscales smaller images
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Approximate decoded byte size, used as the `NSCache` cost so `totalCostLimit` bounds memory.
    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}
