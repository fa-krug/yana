import Foundation

struct FeedGroup: Identifiable, Sendable {
    let id: String      // "user/-/label/Name"
    let label: String
}

struct Feed: Identifiable, Sendable {
    let id: String       // "feed/123"
    var title: String
    var url: String
    var htmlUrl: String
    var categories: [FeedGroup]
    var unreadCount: Int
}
