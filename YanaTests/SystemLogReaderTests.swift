import Foundation
import OSLog
import Testing
@testable import Yana

struct SystemLogReaderTests {

    @Test func mapsOSLogLevelsOntoSyncLogLevels() {
        #expect(SystemLogReader.level(for: .debug) == .debug)
        #expect(SystemLogReader.level(for: .info) == .info)
        #expect(SystemLogReader.level(for: .notice) == .notice)
        #expect(SystemLogReader.level(for: .error) == .error)
        #expect(SystemLogReader.level(for: .fault) == .error)
        #expect(SystemLogReader.level(for: .undefined) == .info)
    }
}
