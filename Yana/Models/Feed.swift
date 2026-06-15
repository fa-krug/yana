import Foundation
import SwiftData

@Model
final class Feed {
    var name: String = ""
    /// Raw value of `AggregatorType`. Use the `type` computed property for typed access.
    var aggregatorType: String = AggregatorType.feedContent.rawValue
    var identifier: String = ""
    var dailyLimit: Int = 20
    var enabled: Bool = true
    var options: AggregatorOptions = AggregatorOptions.feedContent(FeedContentOptions())
    var lastFetchedAt: Date?
    var lastError: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// Template tags applied (as a snapshot) to this feed's articles at import time.
    var tags: [Tag] = []

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article] = []

    var type: AggregatorType {
        get { AggregatorType(rawValue: aggregatorType) ?? .feedContent }
        set { aggregatorType = newValue.rawValue }
    }

    init(
        name: String,
        aggregatorType: AggregatorType,
        identifier: String,
        dailyLimit: Int = 20,
        enabled: Bool = true,
        options: AggregatorOptions? = nil
    ) {
        self.name = name
        self.aggregatorType = aggregatorType.rawValue
        self.identifier = identifier
        self.dailyLimit = dailyLimit
        self.enabled = enabled
        self.options = options ?? aggregatorType.defaultOptions
        self.createdAt = .now
        self.updatedAt = .now
    }
}
