#if DEBUG
import CoreGraphics
import Foundation
import UIKit

/// Forces the Mac window into a fixed size so App Store captures are byte-for-byte reproducible
/// across machines, and silences the asynchronous work that would otherwise bleed into a shot.
///
/// Gated by the `-UITEST_MAC_SCREENSHOTS` launch argument (set only by `MacScreenshotUITests`), so
/// a normal launch is untouched. The default 1440x900pt renders as exactly 2880x1800px on a 2x
/// display — the largest Mac App Store screenshot size.
enum MacScreenshotWindow {
    static let launchArgument = "-UITEST_MAC_SCREENSHOTS"
    static let sizeArgument = "-UITEST_MAC_WINDOW_SIZE"
    static let defaultSize = CGSize(width: 1440, height: 900)

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Parses an optional `-UITEST_MAC_WINDOW_SIZE 1440x900` override, falling back to
    /// `defaultSize` for anything missing, malformed, or non-positive. Pure so it is testable on
    /// every platform (the geometry call below is Catalyst-only, this is not).
    static func size(from arguments: [String]) -> CGSize {
        guard let flagIndex = arguments.firstIndex(of: sizeArgument),
              case let valueIndex = flagIndex + 1,
              valueIndex < arguments.count
        else { return defaultSize }

        let parts = arguments[valueIndex].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return defaultSize }

        return CGSize(width: width, height: height)
    }

    /// Pin the main window to the target size. Call from the Mac root view's `onAppear` — it must
    /// run against the MAIN window's scene only, never the Settings window's.
    ///
    /// Fix 1: falls back to the first connected UIWindowScene when none is .foregroundActive (which
    /// is the common case when onAppear fires during first layout, before activation). A one-shot
    /// UIScene.didActivateNotification observer re-applies the pin once the scene actually activates.
    ///
    /// Fix 2: sizeRestrictions constrain the *content* area, while .Mac(systemFrame:) targets the
    /// AppKit window frame including the title bar. Requesting both at the same size is contradictory,
    /// so we only set sizeRestrictions and rely on the min==max clamp to force the content size.
    /// A bounded poll (every 100 ms, up to 3 s) waits for the content area to converge before
    /// relaxing the restrictions so the window returns to being normally resizable.
    @MainActor
    static func applyWindowGeometryIfRequested() {
        guard isRequested else { return }

        #if targetEnvironment(macCatalyst)
        let target = size(from: ProcessInfo.processInfo.arguments)

        // Prefer the active scene; fall back to any connected window scene so that a call from
        // onAppear (before activation) is never silently dropped.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                       ?? scenes.first
        else { return }

        pinScene(scene, to: target)

        // Re-apply once the scene actually becomes active. This handles the common case where
        // onAppear fires before the scene reaches .foregroundActive, causing the initial pin to
        // target a not-yet-active scene. We poll rather than relying on a Notification observer
        // to avoid threading the non-Sendable UIWindowScene across isolation boundaries.
        Task { @MainActor in
            // Wait for the scene to activate (or give up after a short grace period).
            var activated = false
            for _ in 0..<30 {
                if scene.activationState == .foregroundActive { activated = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if activated {
                pinScene(scene, to: target)
            }
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Apply the size clamp and poll until the content area converges, then relax restrictions.
    @MainActor
    private static func pinScene(_ scene: UIWindowScene, to target: CGSize) {
        // Clamping min == max is what forces the content size. We do NOT call requestGeometryUpdate
        // with the same dimensions because sizeRestrictions targets the content area while
        // systemFrame targets the AppKit frame (including title bar) — requesting both at the same
        // value is contradictory and the window server may ignore or misinterpret the request.
        scene.sizeRestrictions?.minimumSize = target
        scene.sizeRestrictions?.maximumSize = target
        NSLog("[MacScreenshot] sizeRestrictions clamped to %.0fx%.0f; current systemFrame=%@",
              target.width, target.height,
              NSCoder.string(for: scene.effectiveGeometry.systemFrame))

        // Poll until the content area matches the target (window server may take a few frames),
        // then relax the restrictions so the window returns to being resizable.
        Task { @MainActor in
            var converged = false
            for _ in 0..<30 {   // up to ~3 s at 100 ms intervals
                try? await Task.sleep(for: .milliseconds(100))
                let frame = scene.effectiveGeometry.systemFrame
                // The content area is the systemFrame minus the title bar height, so we check
                // only width — it is unaffected by the title bar and is the critical dimension.
                if abs(frame.width - target.width) < 2 {
                    converged = true
                    NSLog("[MacScreenshot] window converged: systemFrame=%@",
                          NSCoder.string(for: frame))
                    break
                }
            }
            if !converged {
                NSLog("[MacScreenshot] WARNING: window did not converge to %.0fx%.0f within 3 s; "
                      + "current systemFrame=%@",
                      target.width, target.height,
                      NSCoder.string(for: scene.effectiveGeometry.systemFrame))
            }
            // Relax regardless so the window stays usable.
            scene.sizeRestrictions?.minimumSize = CGSize(width: 800, height: 600)
            scene.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude)
        }
    }
    #endif
}
#endif
