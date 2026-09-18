#if os(iOS)
import AVKit
import UIKit
import WebKit

/// A modal, full-screen video player for the reader's video embeds. Instead of leaving the app to
/// open the provider's website, a tapped YouTube/Dailymotion poster card plays the video inline in
/// a `WKWebView` that fills the screen (autoplay enabled, native fullscreen controls available).
///
/// Playback uses the provider's privacy-mode embed player (`youtube-nocookie` / Dailymotion's geo
/// player), loaded into a black, edge-to-edge web view with a single close button overlaid. Only
/// providers we can map to an embeddable player are handled here; anything else falls back to
/// opening externally (see `EmbedCardView`).
///
/// **How the player is loaded differs per provider** — see `requiresEmbedderContext(_:)`. Dailymotion
/// is loaded as the top-level document, which makes it first-party: WebKit blocks third-party cookies
/// and DOM storage outright, with no opt-out, so inside an iframe on the synthetic `ReaderWeb.baseOrigin`
/// the player could keep no state at all and re-showed its consent notice on every single playback.
/// YouTube must go the other way and stay inside that iframe: its `/embed/` endpoint is only willing to
/// play when it is actually embedded, and a top-level navigation to it — which carries no `Referer` and
/// no embedder origin — is refused with **"Error 153 — the video player configuration failed"**.
@MainActor
final class ReaderVideoPlayerViewController: UIViewController {

    private let embedURL: URL
    private var webView: WKWebView!
    private var closeButton: UIButton!

    /// Vertical drag distance past which releasing dismisses the player.
    private static let dismissThreshold: CGFloat = 120
    /// Downward flick velocity that dismisses regardless of distance dragged.
    private static let dismissVelocity: CGFloat = 900

    /// Builds a player for the embed, or returns `nil` when the embed isn't a playable video (e.g.
    /// a tweet, or a video whose id couldn't be resolved) — the caller then opens it externally.
    /// A `.video` embed (a direct HLS/MP4 stream, e.g. Reddit `v.redd.it`) plays in a native
    /// `AVPlayerViewController`; iframe providers (YouTube/Dailymotion) play in a `WKWebView`.
    static func make(for embed: Embed) -> PlatformViewController? {
        if embed.provider == .video {
            guard let url = URL(string: embed.externalURL) else { return nil }
            return makeDirectVideoPlayer(url: url)
        }
        guard let url = playerURL(for: embed) else { return nil }
        return ReaderVideoPlayerViewController(embedURL: url)
    }

    /// A native full-screen player for a direct video stream. `AVPlayerViewController` provides the
    /// scrubber, fullscreen, Picture-in-Picture and AirPlay controls; the `.playback` audio session
    /// lets the video play with sound even when the ring/silent switch is on.
    private static func makeDirectVideoPlayer(url: URL) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.modalPresentationStyle = .fullScreen
        controller.allowsPictureInPicturePlayback = true
        controller.player?.play()
        return controller
    }

    private init(embedURL: URL) {
        self.embedURL = embedURL
        super.init(nibName: nil, bundle: nil)
        // Present *over* the reader (not as a full-screen cover): a `.fullScreen` presentation makes
        // UIKit detach the reader's views from the window, so iOS purges the off-screen pages' layer
        // backing / TextKit layout while this player's WKWebView runs on top — making the next swipe
        // after dismissal rebuild that layout under the user's finger. `.overFullScreen` keeps the
        // reader and its prewarmed neighbors alive behind the player, so nothing reloads on return.
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []   // let the embed player autoplay
        if let source = Self.noticeSuppressionScript(for: embedURL) {
            // `.atDocumentStart`, so the flag is in place before the player boots and reads it.
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        addCloseButton()
        addDismissPanGesture()
        if Self.requiresEmbedderContext(embedURL) {
            webView.loadHTMLString(Self.html(embedURL: embedURL), baseURL: URL(string: ReaderWeb.baseOrigin))
        } else {
            webView.load(URLRequest(url: embedURL))
        }
    }

    /// Lets the user swipe the player down to dismiss it, mirroring the sheet-style gesture (the
    /// full-screen presentation style doesn't provide one). The content tracks the drag and either
    /// snaps back or dismisses on release, depending on distance dragged and flick velocity.
    private func addDismissPanGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .changed:
            // Only follow downward drags; clamp upward movement to zero.
            let offset = max(0, translation.y)
            webView.transform = CGAffineTransform(translationX: 0, y: offset)
            closeButton.transform = CGAffineTransform(translationX: 0, y: offset)
            // Fade the content as it slides toward the edge.
            let progress = min(1, offset / (view.bounds.height * 0.6))
            webView.alpha = 1 - progress * 0.5
        case .ended, .cancelled:
            let shouldDismiss = translation.y > Self.dismissThreshold || velocity.y > Self.dismissVelocity
            if shouldDismiss {
                close()
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.webView.transform = .identity
                    self.closeButton.transform = .identity
                    self.webView.alpha = 1
                }
            }
        default:
            break
        }
    }

    private func addCloseButton() {
        closeButton = ReaderCloseButton.add(to: view, target: self, action: #selector(close))
    }

    @objc private func close() {
        // Tear down the web view first so playback (and audio) stops immediately on dismiss.
        webView.loadHTMLString("", baseURL: nil)
        dismiss(animated: true)
    }

}

extension ReaderVideoPlayerViewController: UIGestureRecognizerDelegate {
    /// Only start the dismiss drag for predominantly-downward gestures, so horizontal touches
    /// (e.g. the video player's scrubber) still reach the web view.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
