import Foundation

/// Chooses the remote logo image URL for a feed, in priority order:
/// 1. an API image the aggregator provides (reddit/youtube),
/// 2. the hardcoded brand-site favicon (fixed-brand scrapers),
/// 3. the feed identifier's site favicon (url-based feeds).
/// Returns the URL only; caching is the caller's job.
enum FeedLogoResolver {
    static func logoImageURL(
        for config: FeedConfig,
        aggregator: (any Aggregator)?,
        faviconResolver: (String) async -> String? = { await FaviconResolver.bestIconURL(forSite: $0) }
    ) async -> String? {
        if let api = await aggregator?.logoImageURL(), !api.isEmpty { return api }
        if let brand = config.type.brandSiteURL { return await faviconResolver(brand) }
        if let origin = siteOrigin(of: config.identifier) { return await faviconResolver(origin) }
        return nil
    }

    /// `scheme://host/` for a URL identifier, or nil when the identifier isn't an absolute URL.
    static func siteOrigin(of identifier: String) -> String? {
        guard let comps = URLComponents(string: identifier),
              let scheme = comps.scheme, let host = comps.host else { return nil }
        return "\(scheme)://\(host)/"
    }
}
