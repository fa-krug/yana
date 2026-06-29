import UIKit

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

    init() {
        // Decoded reader images are large; bound the count so a long browsing session can't grow the
        // cache without limit. The pager only keeps a handful of pages alive, so a small window of
        // recently decoded images is plenty.
        cache.countLimit = 32
    }

    /// Synchronous lookup — returns the decoded image if it is already in memory, else nil.
    func cached(_ ref: String) -> UIImage? {
        cache.object(forKey: ref as NSString)
    }

    /// Returns the cached image, or loads it off the main thread, caches it, and returns it.
    /// Coalesces concurrent loads of the same ref onto one task.
    func image(for ref: String) async -> UIImage? {
        if let hit = cached(ref) { return hit }

        let task: Task<UIImage?, Never>
        lock.lock()
        if let existing = inFlight[ref] {
            task = existing
        } else {
            task = Task { await Self.load(ref) }
            inFlight[ref] = task
        }
        lock.unlock()

        let image = await task.value
        if let image { cache.setObject(image, forKey: ref as NSString) }
        lock.lock(); inFlight.removeValue(forKey: ref); lock.unlock()
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
            return await Task.detached { UIImage(contentsOfFile: url.path) }.value
        }
        guard let url = URL(string: ref) else { return nil }
        return await Task.detached {
            (try? Data(contentsOf: url)).flatMap(UIImage.init)
        }.value
    }
}
