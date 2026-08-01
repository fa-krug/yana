import Foundation

/// Bundle version information, for the Settings → About version row.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// e.g. `1.1.0 (1)`.
    static var versionDisplay: String { "\(version) (\(build))" }
}
