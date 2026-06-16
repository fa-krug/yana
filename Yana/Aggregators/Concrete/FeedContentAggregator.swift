import Foundation

/// RSS-only: uses feed entry content as-is (no full-article fetch). Mirrors the server's
/// FeedContentAggregator. Inherits the base pipeline; images are still downloaded (decision 3).
class FeedContentAggregator: RSSPipelineAggregator, @unchecked Sendable {}
