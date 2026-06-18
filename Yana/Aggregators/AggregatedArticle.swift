import Foundation

/// Plain value returned by an aggregator's `aggregate()`. Decoupled from the SwiftData
/// `Article`; `AggregationService` upserts these into the store.
struct AggregatedArticle: Sendable, Equatable {
    var title: String
    var identifier: String   // URL or external id; dedup key within a feed
    var url: String          // link to the original article
    var rawContent: String
    var content: String
    var date: Date
    var author: String
    var iconURL: String?
    /// AI-generated summary, rendered as a block between the article header and body.
    /// Empty when summarization is off or unavailable.
    var summary: String = ""
}
