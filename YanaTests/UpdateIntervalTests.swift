import Testing
import Foundation
@testable import Yana

@MainActor
struct UpdateIntervalTests {
    @Test func secondsMapping() {
        #expect(UpdateInterval.off.seconds == nil)
        #expect(UpdateInterval.min30.seconds == 1800)
        #expect(UpdateInterval.min60.seconds == 3600)
        #expect(UpdateInterval.hour24.seconds == 86400)
    }

    @Test func nearestFromLegacySeconds() {
        #expect(UpdateInterval.nearest(toSeconds: 3600) == .min60)
        #expect(UpdateInterval.nearest(toSeconds: 300)  == .min30)   // 5 min → closest non-off
        #expect(UpdateInterval.nearest(toSeconds: 21600) == .hour8)   // 6h → 8h nearest of the set
        #expect(UpdateInterval.nearest(toSeconds: 0) == .min30)       // never maps to .off
    }

    @Test func settingsRoundTrip() {
        let d = UserDefaults(suiteName: "updateinterval-test")!
        d.removePersistentDomain(forName: "updateinterval-test")
        let s = AppSettings(defaults: d)
        #expect(s.updateInterval == .min60)   // default
        s.updateInterval = .off
        #expect(AppSettings(defaults: d).updateInterval == .off)
    }
}
