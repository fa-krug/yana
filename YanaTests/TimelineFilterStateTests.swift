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

    @Test func readFilterDefaultsToAll() {
        #expect(makeSettings().readFilter == .all)
    }

    @Test func activeWhenReadFilterIsNarrowed() {
        let s = makeSettings()
        s.readFilter = .unread
        #expect(s.isTimelineFilterActive == true)
        s.readFilter = .read
        #expect(s.isTimelineFilterActive == true)
        s.readFilter = .all
        #expect(s.isTimelineFilterActive == false)
    }

    /// Persisted by raw value; an unrecognized stored value degrades to `.all` rather than to a
    /// filter the user never picked.
    @Test func readFilterRoundTripsAndFallsBackToAll() {
        let suite = "filter-state-test.readFilter"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        AppSettings(defaults: defaults).readFilter = .read
        #expect(AppSettings(defaults: defaults).readFilter == .read)

        defaults.set("nonsense", forKey: "settings.readFilter")
        #expect(AppSettings(defaults: defaults).readFilter == .all)
    }

    /// The read filter's exemption key has to encode exactly like `TimelineIdentifiable.stableKey`,
    /// or a displayed article would never match it.
    @Test func anchorStableKeyMatchesTheStableKeyEncoding() {
        let s = makeSettings()
        #expect(s.timelineAnchorStableKey == nil)
        s.timelineAnchorIdentifier = "https://x/a"
        #expect(s.timelineAnchorStableKey == "https://x/a")
        s.timelineAnchorServerID = 42
        #expect(s.timelineAnchorStableKey == "s42")
    }
}
