import AVKit
import UIKit
import WebKit

/// A modal, full-screen video player for the reader's video embeds. Instead of leaving the app to
/// open the provider's website, a tapped YouTube/Dailymotion poster card plays the video inline in
/// a `WKWebView` that fills the screen (autoplay enabled, native fullscreen controls available).
///
/// Playback uses the provider's privacy-mode embed player (`youtube-nocookie` / Dailymotion's geo
/// player) — the same players `EmbedRewriter` targets — loaded into a black, edge-to-edge web view
/// with a single close button overlaid. Only providers we can map to an embeddable player are
/// handled here; anything else falls back to opening externally (see `EmbedCardView`).
///
/// The player URL is loaded as the **top-level document**, deliberately. It used to be wrapped in an
/// `<iframe>` inside a `loadHTMLString` page whose origin was the synthetic `ReaderWeb.baseOrigin`,
/// which made the provider cross-site — and WebKit blocks third-party cookies outright, with no
/// opt-out. The provider could then neither write nor read its own cookies, so every single playback
/// started from scratch: Dailymotion re-showed its consent banner every time. Loading the player
/// first-party lets it keep that state, exactly as it would in a browser tab.
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
    static func make(for embed: Embed) -> UIViewController? {
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

    /// Maps an embed to its inline-playable embed-player URL, or `nil` when it isn't a video we can
    /// play in place.
    static func playerURL(for embed: Embed) -> URL? {
        switch embed.provider {
        case .youtube:
            guard let id = EmbedRewriter.extractYouTubeID(from: embed.externalURL) else { return nil }
            // No `origin=`: that parameter names the *embedder* of an iframe, and this player is
            // loaded top-level (see the type comment). Passing our synthetic origin here would both
            // misstate it and mark the player as embedded.
            let params = "autoplay=1&playsinline=1&controls=1&rel=0&modestbranding=1&fs=1"
            return URL(string: "https://www.youtube-nocookie.com/embed/\(id)?\(params)")
        case .dailymotion:
            guard let id = dailymotionID(from: embed.externalURL) else { return nil }
            return URL(string: "https://geo.dailymotion.com/player.html?video=\(id)&autoplay=1")
        case .video:
            // A direct stream (HLS/MP4): the "player URL" is the stream itself, played via AVPlayer.
            return URL(string: embed.externalURL)
        case .tweet, .generic:
            return nil
        }
    }

    /// Script that suppresses the Dailymotion player's built-in "we use required trackers" notice —
    /// the banner that used to greet every single playback — or `nil` for players that never show it.
    ///
    /// There is no player parameter for this. The full documented runtime parameter set is
    /// `video`/`playlist`/`customConfig`/`scaleMode`/`startTime`/`loop`/`autoplay`, and Dailymotion's
    /// only supported route is for the embedder to run a TCF 2 certified CMP, which the player then
    /// defers to — not something this app should do, since it would mean asserting tracking consent on
    /// the user's behalf.
    ///
    /// So this uses the player's own bookkeeping instead of touching its DOM: the player records that
    /// it already showed the notice in `localStorage` under `dmp_consent_fallback_shown` (observed
    /// TTL: 30 days) and skips the notice while that flag is live. Pre-seeding the flag is therefore
    /// far steadier than hiding `.notification_dialog` would be — it cannot hide the wrong element,
    /// and if Dailymotion ever renames the key the only consequence is that the notice appears again,
    /// exactly as it does today. Note this suppresses the *disclosure*, not the trackers themselves;
    /// per Dailymotion's cookie policy only essential trackers run while that banner is the fallback.
    ///
    /// This only works because the player is the top-level document (see the type comment): DOM
    /// storage is blocked in the cross-site iframe it used to live in, which is precisely why the
    /// player could never remember the notice and re-showed it on every play.
    static func noticeSuppressionScript(for playerURL: URL) -> String? {
        guard let host = playerURL.host?.lowercased(),
              host == "dailymotion.com" || host.hasSuffix(".dailymotion.com") else { return nil }
        return """
        try {
          var ttl = 30 * 24 * 60 * 60 * 1000;
          localStorage.setItem('dmp_consent_fallback_shown',
            JSON.stringify({ expires: Date.now() + ttl, data: true }));
        } catch (e) {}
        """
    }

    private static func dailymotionID(from url: String) -> String? {
        guard let range = url.range(of: #"video/([A-Za-z0-9]+)"#, options: .regularExpression) else { return nil }
        return String(url[range]).replacingOccurrences(of: "video/", with: "")
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
        webView.load(URLRequest(url: embedURL))
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
