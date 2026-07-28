import UIKit

/// The round close button on the reader's full-screen overlays — the image viewer and the video
/// player. Shared so the two cannot drift apart; they previously each hand-rolled the same flat
/// black capsule.
///
/// It uses `UIButton.Configuration.glass()`, the iOS 26 system material, so the overlay's only
/// control reads like the glass buttons in the Mac window toolbar instead of a painted-on black
/// blob — and, being system-drawn, it keeps its contrast over both bright and dark images. Equal
/// content insets plus `.capsule` keep it a circle around the single `xmark` glyph.
enum ReaderCloseButton {
    /// Distance from the safe-area edges. The Mac needs more: the overlay fills a *window*, whose
    /// rounded top corner and title bar crowd a button pinned tight to the trailing edge.
    static var edgeInset: CGFloat {
        #if targetEnvironment(macCatalyst)
        18
        #else
        12
        #endif
    }

    /// Distance below the safe-area top, matched to `edgeInset` on the Mac so the button sits on a
    /// diagonal off the window corner rather than tucked into it.
    static var topInset: CGFloat {
        #if targetEnvironment(macCatalyst)
        18
        #else
        8
        #endif
    }

    /// Pinned side length, so the button is a CIRCLE.
    ///
    /// This cannot be left to the configuration's `contentInsets`: the Mac idiom re-runs a
    /// `UIButton`'s metrics through AppKit control sizing and overrides them, which measured out as
    /// a squat **38 × 17** pill around a 16pt glyph (captured from a running window). An explicit
    /// square wins over that, and iOS is unaffected because the same size is what its symmetric
    /// insets produced anyway.
    static let side: CGFloat = 36

    /// Build the button and pin it to the top-trailing corner of `container`'s safe area.
    ///
    /// `target` is `AnyObject`, not `Any`: under strict concurrency a bare `Any` is non-`Sendable`
    /// and cannot cross into the `@MainActor` call to `addTarget`.
    @MainActor
    @discardableResult
    static func add(to container: UIView, target: AnyObject, action: Selector) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: "xmark")
        config.cornerStyle = .capsule
        // The square below owns the size; insets would only fight the Mac idiom's own metrics.
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
}
