import UIKit
import ImageIO
import UniformTypeIdentifiers

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

    /// Bounds how many images decode at once. The reader body renders every block up front (a
    /// non-lazy `VStack`), so an image-heavy article — e.g. a multi-page Heise story — would
    /// otherwise fire a full-bitmap decode for *every* image simultaneously. Each decode transiently
    /// allocates the source bitmap plus a ≤`maxPixelSize` thumbnail, so a big enough burst spikes
    /// memory past the cache budget and the app is jetsammed (no crash report). Serializing decodes a
    /// few at a time lets the `NSCache` cost limit + LRU eviction bound the resident set between them.
    private static let decodeGate = AsyncSemaphore(limit: 3)

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
        // Hold a decode slot for the whole read+decode so only a few images allocate their bitmaps
        // at the same time (the rest queue on the gate).
        await decodeGate.acquire()
        defer { decodeGate.release() }

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
        // Animated GIFs (e.g. Giphy) decode into a playable multi-frame image; anything else takes
        // the single-frame thumbnail path.
        if let animated = animatedImage(from: source) { return animated }
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

    /// Frames of an animated GIF are held in memory decoded, so cap them below the still-image
    /// budget — reader GIFs are small and a large canvas × many frames would balloon memory.
    private static let maxAnimatedPixelSize = 480
    /// Never keep more than this many frames; a runaway GIF plays truncated rather than exhausting memory.
    private static let maxAnimatedFrames = 240
    /// Hard ceiling on the total decoded bytes of one animated image's frames. All frames are held
    /// resident at once (that's what makes a `UIImage` animate), so without a byte budget a long GIF
    /// at `maxAnimatedPixelSize` would allocate hundreds of MB in a single spike and get the app
    /// jetsammed — with no crash report — the moment it is decoded. The reader preloads lead images
    /// *off-screen* while prewarming neighbor pages, so such a GIF could kill the app on launch
    /// before it was ever displayed (a permanent crash-on-startup loop). Keeping the resident set
    /// under this bound trades a truncated (shorter-looping) GIF for a live app.
    private static let maxAnimatedBytes = 32 * 1024 * 1024

    /// How many frames of an animated image to keep, so the resident frame set stays under the
    /// memory budget. Pure (no ImageIO) so it can be unit-tested. Keeps at least 2 frames whenever
    /// the source has them (so the result still animates rather than silently degrading to a still),
    /// and never exceeds `maxFrames`.
    static func animatedFrameLimit(perFrameBytes: Int, availableFrames: Int,
                                   budgetBytes: Int, maxFrames: Int) -> Int {
        let cap = min(availableFrames, maxFrames)
        guard cap > 1 else { return cap }
        guard perFrameBytes > 0 else { return cap }
        let byBudget = max(2, budgetBytes / perFrameBytes)
        return min(cap, byBudget)
    }

    /// Builds a playable animated `UIImage` from a multi-frame GIF source, downsampling each frame.
    /// Returns nil for still images (single frame or non-GIF) so the caller falls back to the
    /// still-image thumbnail path.
    private static func animatedImage(from source: CGImageSource) -> UIImage? {
        guard let type = CGImageSourceGetType(source), UTType(type as String) == .gif else { return nil }
        let available = CGImageSourceGetCount(source)
        guard available > 1 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxAnimatedPixelSize,
        ]
        // Decode the first frame to learn the per-frame decoded size, then bound how many frames we
        // keep *before* decoding the rest — so the peak allocation during decode is also capped, not
        // just the final image.
        guard let firstCG = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let perFrameBytes = firstCG.bytesPerRow * firstCG.height
        let limit = animatedFrameLimit(perFrameBytes: perFrameBytes, availableFrames: available,
                                       budgetBytes: maxAnimatedBytes, maxFrames: maxAnimatedFrames)
        guard limit > 1 else { return nil }

        var frames: [UIImage] = [UIImage(cgImage: firstCG)]
        frames.reserveCapacity(limit)
        var totalDuration = frameDelay(source, 0)
        for index in 1..<limit {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            totalDuration += frameDelay(source, index)
        }
        guard frames.count > 1 else { return nil }
        if totalDuration <= 0 { totalDuration = Double(frames.count) * 0.1 }
        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }

    /// Per-frame delay for a GIF frame (seconds). Browsers clamp very short delays to ~0.1s, so we
    /// match that to keep fast GIFs from playing unnaturally quickly.
    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }

    /// Approximate decoded byte size, used as the `NSCache` cost so `totalCostLimit` bounds memory.
    /// For animated images all frames are resident, so scale the single-frame estimate by the count.
    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height * max(1, image.images?.count ?? 1)
    }
}
