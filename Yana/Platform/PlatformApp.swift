import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The handful of application-level UIKit calls Yana makes whose AppKit spelling is not obvious
/// enough to leave as an inline `#if` at every site: opening a URL, asking whether the app is
/// frontmost, the two lifecycle notifications the reader hangs its reading-position save off, and
/// the device name shown to the server at pairing time.
///
/// Note what is deliberately *not* here: `ReaderLinkPolicy.openExternally` does not route through
/// `open(_:)`. Its iOS path asks `UIApplication` for a `universalLinksOnly` open first and only
/// falls back to Safari when no installed app claims the URL — behavior that `NSWorkspace.shared
/// .open(_:)` has no equivalent for and that a one-line shim would silently drop. That site keeps
/// its UIKit call and grows a macOS branch of its own later.
enum PlatformApp {
    /// Hand a URL to the system to open in whatever app claims it.
    ///
    /// This is the plain "open it" path only. A caller that needs the universal-link-first behavior
    /// (see the type comment) must not use this.
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// True while the app is the one the user is looking at. Used to suppress a "new articles
    /// arrived" notification for a refresh the user triggered themselves by returning to the app.
    @MainActor
    static var isActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Posted when the app comes back to the front. On iOS that is a genuine
    /// suspended-to-foreground transition; on macOS the app is never suspended, so the nearest
    /// equivalent signal is simply becoming the active application again.
    static var didBecomeActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.willEnterForegroundNotification
        #endif
    }

    /// Posted when the app leaves the front. On iOS this is the last reliable chance to persist
    /// state before the system may terminate the process; on macOS it carries no such urgency, but
    /// it is the same "the user just looked away" moment.
    static var willResignActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.willResignActiveNotification
        #else
        UIApplication.didEnterBackgroundNotification
        #endif
    }

    /// The name this device identifies itself as when pairing with a server.
    ///
    /// Semantically shifted rather than identical across platforms: iOS reports the user-chosen
    /// device name ("Sascha's iPhone"), macOS has no equivalent per-app-visible name and reports the
    /// host name instead ("Saschas-MacBook-Pro"). Both are recognizable in the server's device list,
    /// which is all this string is for.
    @MainActor
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        UIDevice.current.name
        #endif
    }
}
