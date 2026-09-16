#if os(macOS)
import AVKit
import AppKit
import WebKit

/// The AppKit twin of `ReaderVideoPlayerViewController` (`…ViewController.swift`, `#if os(iOS)`).
/// Same type name and the same entry point — `make(for:)` — so `ReaderBlockViewController` and
/// `ReaderVideoPlayerTests` program against one API. The *decisions* (which URL to play, whether the
/// provider has to be embedded, whether a consent-notice flag needs pre-seeding) are not here at
/// all: they live once in `ReaderVideoEmbed.swift`, which both platforms share. Only the hosting
/// differs.
///
/// **How the player is loaded still differs per provider, and the two branches must stay apart.**
/// Dailymotion is loaded as the top-level document, which makes it first-party: WebKit blocks
/// third-party cookies and DOM storage outright, with no opt-out, so inside an iframe on the
/// synthetic `ReaderWeb.baseOrigin` the player could keep no state at all and re-showed its consent
/// notice on every single playback. YouTube must go the other way and stay inside that iframe: its
/// `/embed/` endpoint is only willing to play when it is actually embedded, and a top-level
/// navigation to it — which carries no `Referer` and names no embedder — is refused with
/// **"Error 153 — the video player configuration failed"**.
///
/// What the Mac does differently, and why:
/// - **A window, not a takeover.** Both players are handed to `presentAsModalWindow(_:)`; the Mac
///   convention for "play this" is a window with a close control, not a full-screen mode.
/// - **No drag-to-dismiss.** It is a touch idiom with no pointer equivalent. Esc
///   (`cancelOperation(_:)`) and the window's own close button replace it.
/// - **No `AVAudioSession`.** It does not exist on macOS and nothing replaces it: there is no
///   ring/silent switch to override and no shared session to claim. The direct-stream player is
///   otherwise the same `AVPlayer` with the same Picture-in-Picture affordance.
@MainActor
final class ReaderVideoPlayerViewController: NSViewController {

    private let embedURL: URL
    private var webView: WKWebView!

    /// Builds a player for the embed, or returns `nil` when the embed isn't a playable video (e.g.
    /// a tweet, or a video whose id couldn't be resolved) — the caller then opens it externally.
    /// A `.video` embed (a direct HLS/MP4 stream, e.g. Reddit `v.redd.it`) plays in a native
    /// `AVPlayerView`; iframe providers (YouTube/Dailymotion) play in a `WKWebView`.
    static func make(for embed: Embed) -> PlatformViewController? {
        if embed.provider == .video {
            guard let url = URL(string: embed.externalURL) else { return nil }
            return ReaderDirectVideoPlayerViewController(url: url)
        }
        guard let url = playerURL(for: embed) else { return nil }
        return ReaderVideoPlayerViewController(embedURL: url)
    }

    private init(embedURL: URL) {
        self.embedURL = embedURL
        super.init(nibName: nil, bundle: nil)
        // A 16:9 window at a comfortable default size; the user can resize from there.
        preferredContentSize = NSSize(width: 960, height: 540)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        // `allowsInlineMediaPlayback` is iOS-only — it exists to stop iPhone video taking over the
        // screen, which is not a thing macOS does, so there is nothing to opt out of here.
        config.mediaTypesRequiringUserActionForPlayback = []   // let the embed player autoplay
        if let source = Self.noticeSuppressionScript(for: embedURL) {
            // `.atDocumentStart`, so the flag is in place before the player boots and reads it.
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        // The letterbox around a 16:9 player, and whatever shows before the page paints, stay black
        // rather than flashing the system's default white page background.
        webView.underPageBackgroundColor = .black
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        ReaderCloseButton.add(to: view, target: self, action: #selector(close))

        if Self.requiresEmbedderContext(embedURL) {
            webView.loadHTMLString(Self.html(embedURL: embedURL), baseURL: URL(string: ReaderWeb.baseOrigin))
        } else {
            webView.load(URLRequest(url: embedURL))
        }
    }

    /// Esc. AppKit routes the key here on its own once this controller is in the responder chain,
    /// which is what replaces the iOS swipe-down-to-dismiss gesture.
    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func close() {
        // Tear down the web view first so playback (and audio) stops immediately on dismiss.
        webView.loadHTMLString("", baseURL: nil)
        dismiss(self)
    }
}

/// The native player for a direct HLS/MP4 stream — the macOS counterpart to
/// `AVPlayerViewController`, which does not exist here. `AVPlayerView` supplies the same scrubber,
/// fullscreen, Picture-in-Picture and AirPlay controls; `.floating` is the controls style that
/// overlays them on the video the way the iOS player does rather than reserving a bar below it.
@MainActor
final class ReaderDirectVideoPlayerViewController: NSViewController {
    private let url: URL
    private var playerView: AVPlayerView!

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 960, height: 540)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // No `AVAudioSession` configuration, on purpose: it is iOS-only. On macOS an app simply
        // plays to the default output device, so there is no category to set and no session to
        // activate before playback.
        let playerView = AVPlayerView(frame: NSRect(origin: .zero, size: preferredContentSize))
        playerView.controlsStyle = .floating
        playerView.allowsPictureInPicturePlayback = true
        playerView.player = AVPlayer(url: url)
        self.playerView = playerView
        view = playerView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        playerView.player?.play()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Stop the audio the moment the window goes away, matching the web player's teardown.
        playerView.player?.pause()
    }

    override func cancelOperation(_ sender: Any?) {
        playerView.player?.pause()
        dismiss(self)
    }
}
#endif
