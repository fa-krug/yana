import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("BackgroundRefreshManager")
struct BackgroundRefreshManagerTests {
    @Test func nextBeginDateAddsIntervalToReference() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let result = BackgroundRefreshManager.nextBeginDate(from: now, interval: 1800)
        #expect(result == now.addingTimeInterval(1800))
    }

    @Test func nextBeginDateClampsNonPositiveIntervalToMinimum() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Zero or negative intervals would let iOS run immediately/never; clamp to the floor.
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: 0)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: -500)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
    }
}
