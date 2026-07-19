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
            let params = "autoplay=1&playsinline=1&controls=1&rel=0&modestbranding=1&fs=1&origin=\(ReaderWeb.baseOrigin)"
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
        webView.loadHTMLString(Self.html(embedURL: embedURL), baseURL: URL(string: ReaderWeb.baseOrigin))
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
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "xmark")
        config.baseBackgroundColor = .black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = String(localized: "Close")
        button.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        closeButton = button
    }

    @objc private func close() {
        // Tear down the web view first so playback (and audio) stops immediately on dismiss.
        webView.loadHTMLString("", baseURL: nil)
        dismiss(animated: true)
    }

    /// A self-contained page that paints the embed player edge-to-edge on black. The iframe carries
    /// the same `allow`/`allowfullscreen` capabilities the providers expect for autoplay + fullscreen.
    private static func html(embedURL: URL) -> String {
        let src = embedURL.absoluteString
        let allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>
        html,body{margin:0;padding:0;height:100%;width:100%;background:#000;overflow:hidden}
        .wrap{position:fixed;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center}
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}
        </style></head>
        <body><div class="wrap">
        <iframe src="\(src)" allow="\(allow)" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </div></body></html>
        """
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
