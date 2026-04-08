import Foundation

struct Article: Identifiable, Sendable {
    let id: String          // "tag:google.com,2005:reader/item/000000000000007b"
    var title: String
    var author: String
    var published: Date
    var url: String         // link to original article
    var content: String     // HTML content
    var read: Bool
    var starred: Bool
    var feedTitle: String
    var feedStreamId: String
    var feedHtmlUrl: String

    /// Numeric ID extracted from the tag:google.com format, used for API calls
    var numericId: String {
        // Extract hex from "tag:google.com,2005:reader/item/000000000000007b"
        if let range = id.range(of: "reader/item/") {
            let hex = String(id[range.upperBound...])
            if let value = UInt64(hex, radix: 16) {
                return String(value)
            }
        }
        return id
    }
}
