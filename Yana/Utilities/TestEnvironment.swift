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
}
