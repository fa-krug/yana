# Feed Logos — Design

**Date:** 2026-06-17
**Status:** Approved for planning

## Goal

Give every feed a logo. Display it in the feed list (leading each row) and in the
article reader, integrated into the top-right of the article's title element.

- **Managed/fixed-brand aggregators:** logo is the favicon of a hardcoded brand home page.
- **Reddit & YouTube:** logo is the feed's own per-subreddit / per-channel image, taken
  from the API the app already calls.
- **URL-based aggregators** (`fullWebsite`, `feedContent`, `podcast`): logo is the favicon
  of the feed's own `identifier` site.

## Constraints & Principles

- **Privacy:** never call a third-party favicon service. Logo images are only ever fetched
  from the feed's / brand's own domain (or the Reddit/YouTube APIs the app is already
  authorized to use). No remote image URLs reach the WebView — logos are served through the
  existing `yana-img://<hash>` scheme, exactly like article body images.
- **No bundled binary assets.** Logos are fetched and cached, not shipped in the app bundle.
- **Best-effort & lazy.** Logo resolution never blocks or fails an update. A failure simply
  leaves `logoHash == nil`, to be retried on the next run.
- **Reuse existing infrastructure:** `ImageStore` (download + compress + content-hash cache),
  `ImageSchemeHandler` (`yana-img://`), `HTTPClient`, and the existing Reddit/YouTube clients.

## Data Model

Add one field to `Feed`:

```swift
var logoHash: String?   // content hash of the cached logo image, or nil if not yet resolved
```

SwiftData migration is additive (new optional property) — no manual migration needed.

## Components

### 1. `AggregatorType.brandSiteURL`

A computed property returning the hardcoded brand home page for the fixed-brand scrapers,
`nil` otherwise:

| Type            | brandSiteURL                     |
|-----------------|----------------------------------|
| `heise`         | `https://www.heise.de/`          |
| `merkur`        | `https://www.merkur.de/`         |
| `tagesschau`    | `https://www.tagesschau.de/`     |
| `explosm`       | `https://explosm.net/`           |
| `darkLegacy`    | `https://darklegacycomics.com/`  |
| `caschysBlog`   | `https://stadt-bremerhaven.de/`  |
| `mactechnews`   | `https://www.mactechnews.de/`    |
| `oglaf`         | `https://www.oglaf.com/`         |
| `meinMmo`       | `https://mein-mmo.de/`           |
| all others      | `nil`                            |

(`youtube`, `reddit`, `fullWebsite`, `feedContent`, `podcast` return `nil` — they resolve
via the API path or the feed identifier instead.) Existing constants such as
`HeiseAggregator.heiseURL` may be reused where present.

### 2. `Aggregator.logoImageURL()`

A new optional protocol method providing an API-sourced logo image URL:

```swift
extension Aggregator {
    /// Remote URL of this feed's logo image when the aggregator can source one directly
    /// (e.g. from its API). nil means "derive from the site favicon".
    func logoImageURL() async -> String? { nil }
}
```

Overridden by:

- **`YouTubeAggregator`:** `resolveChannelID(identifier)` → `fetchChannelData(id).iconURL`.
- **`RedditAggregator`:** new `RedditClient.fetchSubredditAbout(subreddit)` →
  `community_icon` (preferred), falling back to `icon_img`. The returned string is HTML-entity
  decoded (Reddit returns `&amp;`-escaped URLs) and empty/whitespace values map to `nil`.

All other aggregators use the default (`nil`).

#### `RedditClient.fetchSubredditAbout`

New method hitting `https://oauth.reddit.com/r/<sub>/about.json` (application-only OAuth, same
as existing calls). Decodes `data.community_icon` and `data.icon_img`; returns the first
non-empty one. Failures return `nil`.

### 3. `FaviconResolver`

```swift
enum FaviconResolver {
    /// Best icon URL for a site, or nil. Fetches the site HTML, parses icon <link>s,
    /// prefers apple-touch-icon then the largest declared size, falls back to /favicon.ico.
    static func bestIconURL(forSite siteURL: String,
                            fetch: @Sendable (URL) async throws -> (Data, String?) = ...) async -> String?

    /// Pure, testable: choose the best icon URL from parsed HTML, resolving relatively to baseURL.
    /// Returns nil when no <link rel> icon is present (caller applies the /favicon.ico fallback).
    static func bestIconURL(fromHTML html: String, baseURL: URL) -> String?
}
```

Selection rules (pure logic, unit-tested):
- Consider `<link>` whose `rel` (case-insensitive, space-split) contains `icon`,
  `shortcut icon`, or `apple-touch-icon`.
- Prefer `apple-touch-icon` / `apple-touch-icon-precomposed`.
- Otherwise prefer the largest `sizes` value (e.g. `32x32` < `180x180`); entries without
  `sizes` rank lowest.
- Resolve relative `href` against the page URL.
- If no candidate, the network wrapper falls back to `<origin>/favicon.ico`.

### 4. `FeedLogoResolver`

Orchestrates the three paths and caches the result:

```swift
struct FeedLogoResolver {
    /// Resolve and cache a logo for the feed, returning its content hash (nil on failure).
    /// 1. aggregator.logoImageURL()  (API path: youtube, reddit)
    /// 2. else AggregatorType.brandSiteURL via FaviconResolver  (fixed-brand scrapers)
    /// 3. else origin(of: config.identifier) via FaviconResolver  (url-based feeds)
    /// Then ImageStore.store(remoteURL:isHeader:false) -> hash.
    func resolveLogoHash(for config: FeedConfig,
                         credentials: AggregatorCredentials,
                         registry: AggregatorRegistry,
                         store: ImageStore) async -> String?
}
```

`isHeader: false` keeps the small-image compression path (logos are icon-sized).

### 5. Integration in `AggregationService`

In the per-feed update path, after building the `FeedConfig`, if `feed.logoHash == nil`:
resolve via `FeedLogoResolver` and, on success, write the hash back onto the `Feed`
(on the main actor) and save. This runs alongside the normal update, never blocking or
failing it. Logo hashes participate in `ImageStore` orphan purging the same way header/body
image hashes do (the retention/cleanup pass must treat `Feed.logoHash` as a referenced hash
to keep).

### 6. Display — Feed list

`FeedLogoView(hash: String?)`: a small (~28pt) rounded view that loads the cached image file
from `ImageStore` for the hash; shows a neutral SF Symbol placeholder (e.g. `globe`) when the
hash is nil or the file is missing. Added leading each row in `FeedsView.row`.

### 7. Display — Article header

In `ArticleWebView.headerHTML`, when `article.feed?.logoHash` exists, emit a small
`<img class="feed-logo" src="yana-img://<hash>">` floated to the top-right of the header so it
sits at the top-right of the title. Add `.feed-logo` CSS (fixed small size, e.g. 28px,
rounded, `float: right; margin-left: 10px`) to the existing stylesheet. The logo scrolls and
zooms as part of the article document, consistent with the current header treatment.

## Data Flow

```
update(feed) ──> FeedConfig
                   │ (if feed.logoHash == nil)
                   ▼
           FeedLogoResolver
             ├─ youtube/reddit ─> Aggregator.logoImageURL() ─┐
             ├─ brand scraper  ─> brandSiteURL ─> FaviconResolver ─┤
             └─ url-based      ─> identifier origin ─> FaviconResolver ─┤
                                                                        ▼
                                              ImageStore.store(isHeader:false) ─> hash
                                                                        ▼
                                              Feed.logoHash = hash (main actor, saved)
                                                                        │
            ┌───────────────────────────────────────────────┬─────────┘
            ▼                                                 ▼
   FeedsView row: FeedLogoView(hash)         ArticleWebView header: <img yana-img://hash>
```

## Error Handling

- Any failure in logo resolution (no API key, network error, no favicon, decode failure)
  results in `logoHash` staying `nil`. The feed update itself is unaffected.
- Missing cached file at display time → placeholder (list) or omitted `<img>` (article).
- Resolution is retried on subsequent updates while `logoHash` is still nil.

## Testing

- `AggregatorType.brandSiteURL`: returns expected URLs for fixed-brand types, `nil` otherwise.
- `FaviconResolver.bestIconURL(fromHTML:baseURL:)`: apple-touch-icon preference; largest-size
  selection; relative-href resolution; nil when no icon link present.
- `FeedLogoResolver` path selection: youtube/reddit take the API path; brand scrapers take
  `brandSiteURL`; url-based feeds take the identifier origin. (Use injected fakes for the
  aggregator/favicon/store seams.)
- `RedditClient.fetchSubredditAbout` decode: prefers `community_icon`, falls back to
  `icon_img`, entity-decodes, empty → nil.
- Default `Aggregator.logoImageURL()` returns nil.

## Out of Scope (YAGNI)

- No manual "refresh logo" UI control (lazy resolution on update is enough).
- No logo customization / override UI.
- No logo in OPML import/export round-trip (logos are re-resolved on next update).
- No high-resolution brand logo curation beyond favicons.
