import Foundation
import Testing
@testable import Yana

@MainActor
struct TimelineFilterStateTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "filter-state-test")!
        defaults.removePersistentDomain(forName: "filter-state-test")
        return AppSettings(defaults: defaults)
    }

    @Test func inactiveByDefault() {
        #expect(makeSettings().isTimelineFilterActive == false)
    }

    @Test func activeWhenTagDisabled() {
        let s = makeSettings()
        s.disabledTagNames = ["News"]
        #expect(s.isTimelineFilterActive == true)
    }

    @Test func activeWhenUntaggedExcluded() {
        let s = makeSettings()
        s.includeUntagged = false
        #expect(s.isTimelineFilterActive == true)
    }
}
