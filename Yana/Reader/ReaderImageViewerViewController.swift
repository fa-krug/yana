import UIKit

/// A modal, full-screen image viewer for the reader's inline images. Tapping an article image opens
/// it here — filling the screen on black — where it can be pinch-zoomed and panned, double-tapped to
/// toggle zoom, and swiped down to dismiss.
///
/// The image is resolved through the same `ReaderImageCache` the inline `ReaderImageView` uses, so a
/// visible image is already decoded and appears immediately. Zoom is driven by a `UIScrollView`
/// (`viewForZooming` → the image view), with the content re-centered on zoom. The close button and
/// swipe-down dismissal mirror `ReaderVideoPlayerViewController` for a consistent full-screen feel.
@MainActor
final class ReaderImageViewerViewController: UIViewController {

    private let ref: String
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var closeButton: UIButton!

    /// Vertical drag distance past which releasing dismisses the viewer.
    private static let dismissThreshold: CGFloat = 120
    /// Downward flick velocity that dismisses regardless of distance dragged.
    private static let dismissVelocity: CGFloat = 900
    private static let maximumZoomScale: CGFloat = 4

    init(ref: String) {
        self.ref = ref
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maximumZoomScale
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        addDoubleTapGesture()
        addCloseButton()
        addDismissPanGesture()
        loadImage()
    }

    private func loadImage() {
        // Seed synchronously from the cache so a visible image shows on the first frame.
        if let cached = ReaderImageCache.shared.cached(ref) {
            imageView.image = cached
            return
        }
        Task {
            imageView.image = await ReaderImageCache.shared.image(for: ref)
        }
    }

    // MARK: - Zoom

    private func addDoubleTapGesture() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            // Zoom in centered on the tapped point.
            let point = gesture.location(in: imageView)
            let scale = scrollView.maximumZoomScale
            let size = scrollView.bounds.size
            let rect = CGRect(x: point.x - (size.width / scale) / 2,
                              y: point.y - (size.height / scale) / 2,
                              width: size.width / scale,
                              height: size.height / scale)
            scrollView.zoom(to: rect, animated: true)
        }
    }

    // MARK: - Chrome & dismiss

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

    /// Lets the user swipe the image down to dismiss when it isn't zoomed in (the scroll view owns
    /// panning while zoomed). Mirrors the video player's drag-to-dismiss.
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
            let offset = max(0, translation.y)
            scrollView.transform = CGAffineTransform(translationX: 0, y: offset)
            closeButton.transform = CGAffineTransform(translationX: 0, y: offset)
            let progress = min(1, offset / (view.bounds.height * 0.6))
            scrollView.alpha = 1 - progress * 0.5
        case .ended, .cancelled:
            let shouldDismiss = translation.y > Self.dismissThreshold || velocity.y > Self.dismissVelocity
            if shouldDismiss {
                close()
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.scrollView.transform = .identity
                    self.closeButton.transform = .identity
                    self.scrollView.alpha = 1
                }
            }
        default:
            break
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

extension ReaderImageViewerViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    /// Keep the image centered while it's smaller than the viewport (i.e. at or near min zoom).
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let offsetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let offsetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }
}

extension ReaderImageViewerViewController: UIGestureRecognizerDelegate {
    /// Only start the dismiss drag for predominantly-downward gestures while the image is not zoomed
    /// in, so panning a zoomed image reaches the scroll view instead.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard scrollView.zoomScale <= scrollView.minimumZoomScale else { return false }
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
