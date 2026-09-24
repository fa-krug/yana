import Foundation

/// Answers whether this process is an `xcodebuild test` unit-test host.
///
/// `XCTestConfigurationFilePath` is set by the test runner in the host application's environment
/// for a unit-test bundle, and is absent from a normally launched app -- including the app a UI
/// test drives, which is a separate process the runner only talks to over the automation bridge.
/// That is exactly the distinction wanted here: a unit test runs *inside* the app's own process
/// and therefore sees the developer's real `UserDefaults` and login Keychain, while a UI test runs
/// against a simulator container with its own fixture pairing.
enum TestEnvironment {
    static let isRunningUnitTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    /// Whether process-wide storage must be swapped for a throwaway test copy. `#if DEBUG` so a
    /// release build can never take the redirected path.
    ///
    /// **Why this exists: a macOS unit-test run wiped the developer's real library and unpaired
    /// the device.** On macOS the unit-test host *is* the real app, in its real sandbox container,
    /// so `AppContainer.shared`, the login Keychain, the timeline index cache and
    /// `UserDefaults.standard` are all the developer's own. `PairingSyncTests` calls
    /// `PairingSync.resetAndFullSync` (which runs `LocalLibraryReset.wipe` on `AppContainer.shared`)
    /// and `KeychainService.deleteDeviceToken()`, and a dozen other suites delete or overwrite the
    /// token. On the iOS Simulator the same code only touches the simulator's own container, which
    /// is why this went unnoticed. Each of those four stores consults this flag and points
    /// somewhere disposable instead, so no test can reach real data however it is written.
    static var isolatesProcessStorage: Bool {
        #if DEBUG
        return isRunningUnitTests
        #else
        return false
        #endif
    }
}
