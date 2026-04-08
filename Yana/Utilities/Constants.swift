import Foundation

enum AppConstants {
    static let bundleID = "de.fa-krug.Yana"
    static let keychainService = "de.fa-krug.Yana"

    // Google Reader API paths
    static let greaderBasePath = "/api/greader"
    static let greaderClientLogin = "/accounts/ClientLogin"
    static let greaderToken = "/reader/api/0/token"
    static let greaderUserInfo = "/reader/api/0/user-info"
    static let greaderSubscriptionList = "/reader/api/0/subscription/list"
    static let greaderSubscriptionEdit = "/reader/api/0/subscription/edit"
    static let greaderSubscriptionQuickAdd = "/reader/api/0/subscription/quickadd"
    static let greaderTagList = "/reader/api/0/tag/list"
    static let greaderEditTag = "/reader/api/0/edit-tag"
    static let greaderDisableTag = "/reader/api/0/disable-tag"
    static let greaderMarkAllAsRead = "/reader/api/0/mark-all-as-read"
    static let greaderUnreadCount = "/reader/api/0/unread-count"
    static let greaderStreamItemIDs = "/reader/api/0/stream/items/ids"
    static let greaderStreamContents = "/reader/api/0/stream/items/contents"
    static let greaderPreferenceList = "/reader/api/0/preference/list"
    static let greaderStreamPreferenceList = "/reader/api/0/preference/stream/list"

    // GReader tag constants
    static let tagRead = "user/-/state/com.google/read"
    static let tagStarred = "user/-/state/com.google/starred"
    static let tagReadingList = "user/-/state/com.google/reading-list"
}
