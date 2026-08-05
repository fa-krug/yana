import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AppSettings.aiMode")
struct AppSettingsAIModeTests {
    @Test func defaultsToServer() {
        let defaults = UserDefaults(suiteName: "AppSettingsAIModeTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.aiMode == .server)
    }

    @Test func roundTripsAppleIntelligence() {
        let defaults = UserDefaults(suiteName: "AppSettingsAIModeTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.aiMode = .appleIntelligence
        #expect(settings.aiMode == .appleIntelligence)
    }

    @Test func serverBaseURLDefaultsEmpty() {
        let defaults = UserDefaults(suiteName: "AppSettingsAIModeTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.serverBaseURL == "")
        settings.serverBaseURL = "https://yana.example.com"
        #expect(settings.serverBaseURL == "https://yana.example.com")
    }
}
