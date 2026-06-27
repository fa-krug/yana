import UIKit
import WebKit

/// A small reserve of pre-instantiated, blank-warmed `WKWebView`s — a port of NetNewsWire's
/// `WebViewProvider`/`PreloadedWebView`. The slow part of showing an article is creating the
/// `WKWebView` and bringing its Web Content process up to a first layout; doing that ahead of time
/// against a blank document means a reader page only pays for `loadHTMLString` of its own content
/// when it adopts a view. The reserve refills itself back to `minimumDepth` after each dequeue, so
/// neighbor prewarming and a burst of swipes keep landing on already-warm views instead of
/// cold-allocating on the main thread.
///
/// This complements the single-anchor warm (`ReaderWarmup`): the anchor page still adopts its
/// fully-rendered launch warm for the fastest possible first paint, while every other page — and any
/// anchor warm that misses — pulls a blank-warmed view from here rather than allocating cold.
@MainActor
final class ReaderWebViewPool {
    static let shared = ReaderWebViewPool()

    /// NetNewsWire keeps 3 ready. The reader prewarms a ±radius burst around the current page, so a
    /// few warm views in reserve absorb a swipe run before the pool falls back to cold allocation.
    static let minimumDepth = 3

    private var reserve: [WKWebView] = []

    /// Number of warm views currently held. Exposed for tests and instrumentation.
    var depth: Int { reserve.count }

    init() {}

    /// Fill the reserve up to `minimumDepth` with blank-loaded web views. Cheap and idempotent —
    /// safe to call on launch, after a dequeue, or after a memory trim.
    func preload(minimumDepth: Int = ReaderWebViewPool.minimumDepth) {
        while reserve.count < minimumDepth {
            reserve.append(Self.makeBlankWarmedWebView())
        }
    }

    /// Hand out a warm view, scheduling a refill behind it. Falls back to a freshly blank-warmed
    /// view if the reserve is momentarily empty (dequeued faster than it refilled).
    func dequeue() -> WKWebView {
        let webView = reserve.isEmpty ? Self.makeBlankWarmedWebView() : reserve.removeLast()
        // Refill on the next runloop so the dequeue returns immediately and the new view's process
        // spin-up overlaps the caller rendering its content.
        DispatchQueue.main.async { [weak self] in self?.preload() }
        return webView
    }

    /// Release the reserve under memory pressure; `preload`/`dequeue` rebuild it on demand.
    func drain() { reserve.removeAll() }

    private static func makeBlankWarmedWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: ReaderWebView.makeConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Load a blank document so the Web Content process spawns and performs its first layout now;
        // a page's real article HTML supersedes it via loadHTMLString on adoption.
        webView.loadHTMLString(ReaderWeb.blankHTML, baseURL: ReaderWeb.pageBaseURL)
        return webView
    }
}
