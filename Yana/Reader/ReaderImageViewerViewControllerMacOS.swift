#if os(macOS)
import AppKit

/// The AppKit twin of `ReaderImageViewerViewController` (`…ViewController.swift`, `#if os(iOS)`).
/// Same type name and the same entry point — `init(ref:)` — so `ReaderBlockViewController` does not
/// fork. Clicking an article image opens it here, on black, where it can be zoomed and panned.
///
/// **This is much smaller than its iOS twin, and the difference is AppKit doing the work, not
/// behavior being dropped.** `NSScrollView` implements magnification itself: `allowsMagnification`
/// plus a min/max range gives trackpad pinch, the standard zoom gestures and the pan-while-zoomed
/// interaction for free. So the whole `UIScrollViewDelegate` extension — `viewForZooming` and the
/// `scrollViewDidZoom` inset arithmetic that re-centered a smaller-than-viewport image — has no
/// counterpart to port: the document view is sized to the viewport on every layout (see
/// `viewDidLayout`) and the image letterboxes itself inside it, which is what that arithmetic was
/// reproducing by hand.
///
/// **What genuinely goes away is drag-to-dismiss.** A downward flick that closes the view is a touch
/// idiom with no pointer equivalent, and on a window it would fight the title bar drag. Esc
/// (`cancelOperation(_:)`), the close button and the window's own close control replace it — which
/// is also why this is presented with `presentAsModalWindow(_:)` rather than as a full-screen
/// takeover: the Mac convention for "look at this image" is a window.
@MainActor
final class ReaderImageViewerViewController: NSViewController {

    private let ref: String
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()

    private static let maximumZoomScale: CGFloat = 4

    init(ref: String) {
        self.ref = ref
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 900, height: 700)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The whole zoom interaction, in three lines. `minMagnification == 1` keeps the fitted image
        // as the floor, so a pinch out always returns to exactly "fills the window".
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = Self.maximumZoomScale
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // `.scaleProportionallyUpOrDown` is AppKit's spelling of `.scaleAspectFit`: the image fills
        // as much of the document view as its aspect ratio allows and is centered in the remainder.
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // Deliberately NOT auto-layout-managed. A document view whose edges are constrained to the
        // clip view cannot grow past it, and the clip view's bounds shrink as magnification rises —
        // so constraining it would silently disable panning at every zoom level above 1. The frame
        // is set from the scroll view's own (magnification-independent) bounds in `viewDidLayout`.
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.frame = NSRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.documentView = imageView

        addDoubleClickGesture()
        ReaderCloseButton.add(to: view, target: self, action: #selector(close))
        loadImage()
    }

    /// Keep the fitted size in step with the window, but only while the user is not zoomed in —
    /// resizing the document out from under a magnified view would throw away their pan position.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard abs(scrollView.magnification - scrollView.minMagnification) < 0.001 else { return }
        imageView.frame = NSRect(origin: .zero, size: scrollView.bounds.size)
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

    private func addDoubleClickGesture() {
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        if scrollView.magnification > scrollView.minMagnification {
            scrollView.animator().magnification = scrollView.minMagnification
        } else {
            // Zoom in centered on the clicked point. `setMagnification(_:centeredAt:)` wants a point
            // in the *document* view's coordinates, which is where the click actually landed.
            let point = gesture.location(in: imageView)
            scrollView.animator().setMagnification(scrollView.maxMagnification, centeredAt: point)
        }
    }

    // MARK: - Dismiss

    /// Esc, routed here by AppKit once this controller is in the responder chain. This plus the
    /// close button and the window's close control are what replace the iOS drag-to-dismiss.
    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func close() { dismiss(self) }
}
#endif
