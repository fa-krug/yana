import CloudKit
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleZoneConflictTolerance")
struct ArticleZoneConflictToleranceTests {
    private func conflict() -> CKError {
        CKError(.serverRecordChanged, userInfo: ["ServerErrorDescription": "record to insert already exists"])
    }

    /// A push where every record already exists on the server is self-healing (the store fetches the
    /// change tag and re-queues as an update), so it must NOT be surfaced as a user-facing error.
    @Test func allServerRecordChangedIsRecoverable() {
        let partial = CKError(.partialFailure,
                              userInfo: [CKPartialErrorsByItemIDKey: ["a": conflict(), "b": conflict()]])
        #expect(CloudKitArticleZoneStore.isFullyRecoverableConflict(partial))
    }

    /// A mixed partial failure (one genuine error) is NOT recoverable — it must propagate.
    @Test func mixedFailureIsNotRecoverable() {
        let genuine = CKError(.quotaExceeded)
        let partial = CKError(.partialFailure,
                              userInfo: [CKPartialErrorsByItemIDKey: ["a": conflict(), "b": genuine]])
        #expect(!CloudKitArticleZoneStore.isFullyRecoverableConflict(partial))
    }

    /// A non-partial error (e.g. a flat auth failure) is never treated as a recoverable conflict.
    @Test func flatErrorIsNotRecoverable() {
        #expect(!CloudKitArticleZoneStore.isFullyRecoverableConflict(CKError(.notAuthenticated)))
    }

    /// An empty partial failure is not treated as recoverable (nothing was actually re-queued).
    @Test func emptyPartialIsNotRecoverable() {
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [:] as [AnyHashable: Error]])
        #expect(!CloudKitArticleZoneStore.isFullyRecoverableConflict(partial))
    }
}
