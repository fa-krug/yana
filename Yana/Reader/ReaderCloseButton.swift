#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The round close button on the reader's full-screen overlays — the image viewer and the video
/// player. Shared so the two cannot drift apart; they previously each hand-rolled the same flat
/// black capsule.
///
/// On iOS it uses `UIButton.Configuration.glass()`, the iOS 26 system material, so the overlay's
/// only control reads like the glass buttons in the Mac window toolbar instead of a painted-on
/// black blob — and, being system-drawn, it keeps its contrast over both bright and dark images.
/// Equal content insets plus `.capsule` keep it a circle around the single `xmark` glyph. AppKit's
/// nearest equivalent is `NSButton`'s `.circular` bezel, which is likewise system-drawn and
/// vibrancy-aware, so the same "let the system draw the chrome" rule holds on both platforms.
enum ReaderCloseButton {
    /// Distance from the safe-area trailing edge.
    ///
    /// **12pt on both platforms now.** The Mac used to take 18 — a number *measured against a
    /// Catalyst window*, whose rounded top corner and title bar crowded a button pinned tight to the
    /// trailing edge of a view that ran the full height of the window. A native macOS overlay is
    /// presented with `presentAsModalWindow(_:)`, so the image/video sits in a content view that
    /// already begins below the title bar and has no corner of its own to clear. With nothing left
    /// to compensate for, the extra 6pt only floated the button away from the edge; 12pt is AppKit's
    /// ordinary control margin and matches what iOS already used.
    static let edgeInset: CGFloat = 12

    /// Distance below the safe-area top. Also flattened to one value with `edgeInset`'s reasoning —
    /// the Mac's 18 existed to push the button off a Catalyst window corner that a native content
    /// view does not have.
    static let topInset: CGFloat = 12

    /// Pinned side length, so the button is a CIRCLE.
    ///
    /// This cannot be left to the configuration's `contentInsets`: the Mac Catalyst idiom used to
    /// re-run a `UIButton`'s metrics through AppKit control sizing and override them, which measured
    /// out as a squat **38 × 17** pill around a 16pt glyph (captured from a running window). An
    /// explicit square won over that, and the native AppKit button wants the same treatment for the
    /// same reason — a `.circular` bezel sizes itself to its own idea of a control, not to a
    /// full-bleed overlay's.
    static let side: CGFloat = 36

    #if os(macOS)
    /// Build the button and pin it to the top-trailing corner of `container`'s safe area.
    @MainActor
    @discardableResult
    static func add(to container: PlatformView, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))
                ?? NSImage(),
            target: target,
            action: action
        )
        button.bezelStyle = .circular
        button.isBordered = true
        button.title = ""
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(String(localized: "Close"))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
                                        constant: topInset),
            button.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor,
                                             constant: -edgeInset),
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side),
        ])
        return button
    }
    #else
    /// Build the button and pin it to the top-trailing corner of `container`'s safe area.
    ///
    /// `target` is `AnyObject`, not `Any`: under strict concurrency a bare `Any` is non-`Sendable`
    /// and cannot cross into the `@MainActor` call to `addTarget`.
    @MainActor
    @discardableResult
    static func add(to container: PlatformView, target: AnyObject, action: Selector) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: "xmark")
        config.cornerStyle = .capsule
        // The square below owns the size; insets would only fight the system's own metrics.
        config.contentInsets = .zero

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = String(localized: "Close")
        button.addTarget(target, action: action, for: .touchUpInside)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
                                        constant: topInset),
            button.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor,
                                             constant: -edgeInset),
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side),
        ])
        return button
    }
    #endif
}
