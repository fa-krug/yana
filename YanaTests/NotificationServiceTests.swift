import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("NewArticleNotification")
struct NotificationServiceTests {
    @Test func notifiesOnlyWhenEnabledAuthorizedAndPositive() {
        #expect(NewArticleNotification.shouldNotify(enabled: true, authorized: true, insertedCount: 3) == true)
        #expect(NewArticleNotification.shouldNotify(enabled: false, authorized: true, insertedCount: 3) == false)
        #expect(NewArticleNotification.shouldNotify(enabled: true, authorized: false, insertedCount: 3) == false)
        #expect(NewArticleNotification.shouldNotify(enabled: true, authorized: true, insertedCount: 0) == false)
    }

    @Test func bodyMentionsCount() {
        #expect(NewArticleNotification.body(count: 5).contains("5"))
        #expect(NewArticleNotification.body(count: 1).contains("1"))
    }
}
