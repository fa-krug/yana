import Foundation

// MARK: - User Info

struct GReaderUserInfo: Codable, Sendable {
    let userId: String
    let userName: String
    let userProfileId: String
    let userEmail: String
}

// MARK: - Subscriptions

struct GReaderSubscriptionList: Codable, Sendable {
    let subscriptions: [GReaderSubscription]
}

struct GReaderSubscription: Codable, Sendable {
    let id: String
    let title: String
    let categories: [GReaderCategory]
    let url: String
    let htmlUrl: String?
}

struct GReaderCategory: Codable, Sendable {
    let id: String
    let label: String
}

// MARK: - Tags

struct GReaderTagList: Codable, Sendable {
    let tags: [GReaderTag]
}

struct GReaderTag: Codable, Sendable {
    let id: String
}

// MARK: - Unread Counts

struct GReaderUnreadCountResponse: Codable, Sendable {
    let max: Int
    let unreadcounts: [GReaderUnreadCount]
}

struct GReaderUnreadCount: Codable, Sendable {
    let id: String
    let count: Int
    let newestItemTimestampUsec: String
}

// MARK: - Stream Item IDs

struct GReaderItemIdList: Codable, Sendable {
    let itemRefs: [GReaderItemRef]
}

struct GReaderItemRef: Codable, Sendable {
    let id: String
}

// MARK: - Stream Contents

struct GReaderStreamContents: Codable, Sendable {
    let direction: String?
    let id: String
    let title: String
    let items: [GReaderItem]
    let continuation: String?
}

struct GReaderItem: Codable, Sendable {
    let id: String
    let title: String?
    let published: Int?
    let updated: Int?
    let crawlTimeMsec: String?
    let timestampUsec: String?
    let categories: [String]?
    let alternate: [GReaderLink]?
    let canonical: [GReaderLink]?
    let origin: GReaderOrigin?
    let summary: GReaderContent?
    let content: GReaderContent?
    let author: String?
}

struct GReaderLink: Codable, Sendable {
    let href: String
}

struct GReaderOrigin: Codable, Sendable {
    let streamId: String
    let title: String
    let htmlUrl: String?
}

struct GReaderContent: Codable, Sendable {
    let direction: String?
    let content: String
}

// MARK: - Quick Add

struct GReaderQuickAddResult: Codable, Sendable {
    let query: String
    let numResults: Int
    let streamId: String?
    let streamName: String?
}
