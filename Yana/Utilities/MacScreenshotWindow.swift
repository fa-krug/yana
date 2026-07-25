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

    /// Silence work that would otherwise land in a captured frame.
    ///
    /// The app under test shares the real `de.fa-krug.Yana` container, so a developer's persisted
    /// "iCloud sync on" would pull their actual feeds mid-capture and destroy determinism. Writing
    /// to the shared container is deliberate: the run also wipes the library via
    /// `-UITEST_RESET_LIBRARY`, so this is already a throwaway state.
    @MainActor
    static func quietBackgroundWorkIfRequested() {
        guard isRequested else { return }
        AppSettings().iCloudSyncEnabled = false
    }

    /// Pin the main window to the target size. Call from the Mac root view's `onAppear` — it must
    /// run against the MAIN window's scene only, never the Settings window's.
    @MainActor
    static func applyWindowGeometryIfRequested() {
        guard isRequested else { return }

        #if targetEnvironment(macCatalyst)
        let target = size(from: ProcessInfo.processInfo.arguments)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        // Clamping min == max is what actually forces the size: requestGeometryUpdate alone is a
        // request the window server may round or refuse, and MacRootView's sidebar minimum would
        // otherwise let the window settle at a different width. Relax the restrictions afterwards
        // so the window is still a normal, resizable window for anyone watching the run.
        scene.sizeRestrictions?.minimumSize = target
        scene.sizeRestrictions?.maximumSize = target
        // Use the scene's true current position so the window stays where the user last left it.
        // `effectiveGeometry.systemFrame` is iOS 16+ and available on Mac Catalyst.
        let currentOrigin = scene.effectiveGeometry.systemFrame.origin
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: currentOrigin, size: target))) { _ in }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            scene.sizeRestrictions?.minimumSize = CGSize(width: 800, height: 600)
            scene.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude)
        }
        #endif
    }
}
#endif
