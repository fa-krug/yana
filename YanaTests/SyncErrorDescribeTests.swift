import CloudKit
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("SyncErrorDescribe")
struct SyncErrorDescribeTests {
    /// A `CKSyncEngine`-style server rejection (schema field/type not in Production) is buried inside
    /// a `.partialFailure`. `describe` should surface the server's reason and the specific code,
    /// not the opaque outer wrapper.
    @Test func surfacesServerRejectionReasonFromPartialFailure() {
        let leaf = CKError(.serverRejectedRequest,
                           userInfo: ["ServerErrorDescription": "unknown field 'isStarred'"])
        let partial = CKError(.partialFailure,
                              userInfo: [CKPartialErrorsByItemIDKey: ["itemA": leaf]])

        let described = ConfigSyncService.describe(partial)

        #expect(described.contains("unknown field 'isStarred'"))
        #expect(described.contains("serverRejectedRequest"))
    }

    /// A server rejection with no human-readable server description still exposes the code so the
    /// failure is at least identifiable.
    @Test func surfacesCodeWhenNoServerReason() {
        let described = ConfigSyncService.describe(CKError(.serverRejectedRequest))
        #expect(described.contains("serverRejectedRequest"))
    }

    /// Friendly, actionable messages must still win even when the recognized code is nested inside
    /// an outer wrapper error rather than at the top level.
    @Test func nestedNotAuthenticatedStaysFriendly() {
        let leaf = CKError(.notAuthenticated)
        let wrapper = NSError(domain: "CKSyncEngine", code: 1,
                              userInfo: [NSUnderlyingErrorKey: leaf])

        #expect(ConfigSyncService.describe(wrapper)
                == String(localized: "Sign in to iCloud in Settings to sync."))
    }

    @Test func plainQuotaExceededStaysFriendly() {
        #expect(ConfigSyncService.describe(CKError(.quotaExceeded))
                == String(localized: "Your iCloud storage is full."))
    }
}
