import Foundation
@preconcurrency import UserNotifications

/// Abstraction over the system notification center so the aggregation path can be tested
/// with a fake (no real authorization prompts or scheduled notifications).
protocol Notifying: Sendable {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func postNewArticles(count: Int) async
}

/// Pure gating + copy for the "new articles" notification. Kept separate from the
/// system-touching `NotificationService` so the decision logic is unit-testable.
enum NewArticleNotification {
    static func shouldNotify(enabled: Bool, authorized: Bool, insertedCount: Int) -> Bool {
        enabled && authorized && insertedCount > 0
    }

    static func body(count: Int) -> String {
        // Automatic grammar agreement: "1 new article" vs "5 new articles".
        String(localized: "^[\(count) new article](inflect: true)")
    }

    static let title = String(localized: "Yana")
}

/// Concrete `Notifying` backed by `UNUserNotificationCenter`.
struct NotificationService: Notifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func postNewArticles(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = NewArticleNotification.title
        content.body = NewArticleNotification.body(count: count)
        let request = UNNotificationRequest(
            identifier: "yana.new-articles",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
