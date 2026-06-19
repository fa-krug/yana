# Reader Reload: always single-article, never feed-wide

**Date:** 2026-06-19
**Status:** Approved (design)

## Problem

The reader overflow menu's **Reload** ("Neu laden") is documented as reloading only
the current article, but in practice it falls back to reloading the entire parent feed
for any source that doesn't support a per-article re-fetch.

`AggregationService.forceReload(article:)` (`Yana/Services/AggregationService.swift:227`)
falls back to `forceReload(feed:)` in two cases:

1. The aggregator can't be constructed (`:237`).
2. `aggregator.refetch(seed)` returns `nil` or throws (`:255`).

Only `FullWebsiteAggregator` (and its scraper/comic subclasses) override `refetch()` with
a real per-URL re-scrape. `RSSPipelineAggregator.refetch` returns `nil`
(`Yana/Aggregators/Concrete/RSSPipelineAggregator.swift:44`), and `YouTubeAggregator` /
`RedditAggregator` don't override it at all, so for `feedContent`, `podcast`, `youtube`,
and `reddit` the reader's Reload silently re-imports the whole feed.

## Goal

Reader Reload must **only ever fetch and write the current article** — for every source
type. It must never insert or modify any other article. The feed-wide reload path
(`forceReload(feed:)`) remains, but is reachable only from the Feeds screen's explicit
"Reload" swipe — never from the reader.

## Key finding: every source can re-fetch a single item

| Source | Single-article re-fetch mechanism |
|---|---|
| `fullWebsite`, scrapers, comics | Already implemented: re-scrape the article's own page URL via `enrich`. |
| `feedContent` (RSS/Atom), `podcast` | Fetch the feed payload, select the entry whose `link` matches the seed identifier, enrich only that entry. |
| `youtube` | Parse the video ID from the watch URL, fetch that one video (`videos?id=…`) + its comments. |
| `reddit` | Parse the post ID from the permalink, fetch `/comments/<id>.json` (returns the post + comments in one request). |

No source is stuck on a listing-only model in a way that forces a feed reload.

## Design

Give every concrete aggregator a real `refetch(_ seed:)`, and remove both
`forceReload(feed:)` fallbacks from `forceReload(article:)`.

### 1. `RSSPipelineAggregator.refetch`
Replace the `nil` stub with:
- Call `fetchEntries()`.
- Find the entry where `entry.link == seed.identifier`.
- If found, run it through `makeArticle(from:)` + `enrich(_:entry:)` and return the result.
- If no entry matches (article dropped from the feed), return `nil`.

`FeedContentAggregator` and `PodcastAggregator` inherit this unchanged.
`FullWebsiteAggregator` keeps its existing per-URL override.

Network note: this downloads the full feed payload (unavoidable — RSS content lives in the
feed document), but only the matching entry is enriched and returned. The store write is
scoped to that one article.

### 2. `YouTubeAggregator.refetch`
- Parse the video ID from `seed.url` (`https://www.youtube.com/watch?v=<id>`).
- `client.fetchVideoDetails([id])` → the one video (snippet has title/description/publishedAt/thumbnails).
- `client.fetchVideoComments(videoID: id, max: options.commentLimit)`.
- Rebuild content exactly as `aggregate()` does for a single video (embed + description +
  comments via `buildContentHTML` + `ContentFormatter.format`).
- Reuse `seed.author` (no channel/playlist resolution needed).
- Return `nil` if the ID can't be parsed or the video is gone.

### 3. `RedditAggregator.refetch`
- Parse the post ID from `seed.identifier` (`reddit.com/r/<sub>/comments/<id>/…`); subreddit
  comes from `config.identifier` (normalized).
- Add `RedditClient.fetchPost(subreddit:postID:)` that hits `/comments/<id>.json` and decodes
  the **post** from listing element 0 (a `RedditListing`-shaped envelope of `RedditPostData`).
  The existing comment path (element 1) is unchanged.
- Run the post through the existing `buildContent` / `headerImageURL` / `ContentFormatter.format`
  path, identical to one iteration of `aggregate()`'s loop.
- Return `nil` if the ID can't be parsed or the post is gone.

Implementation note: the existing `buildContent` path calls `client.fetchComments` internally,
which hits the same `/comments/<id>.json` endpoint that `fetchPost` uses. This means a single
refetch issues that request twice. Acceptable for a one-off user action; the plan may optionally
collapse it into one call if cheap.

### 4. `AggregationService.forceReload(article:)`
- Remove the `makeAggregator == nil` fallback to `forceReload(feed:)` — if the aggregator can't
  be built, return 0.
- Remove the `refreshed == nil` fallback to `forceReload(feed:)` — if `refetch` returns `nil`
  (article genuinely gone from the source), return 0.
- Keep the seed construction, AI processing, and single-article upsert path unchanged.

A return of 0 surfaces through the existing `RefreshOutcome.message` path in
`ReaderScreen.forceUpdateArticle` (`Yana/Reader/ReaderHostView.swift:286`) as a "no new
content" style status — no feed reload, no jump in the timeline.

The base `Aggregator.refetch` default stays `nil` as a safety net, but every concrete type now
overrides it.

## Out of scope
- The Feeds screen's per-feed "Reload" swipe (`forceReload(feed:)`) is unchanged — feed-wide
  reload remains available there.
- No change to "Update" semantics (intake-window-filtered new-article fetch).

## Testing
- `RSSPipelineAggregator.refetch` returns the matching entry; returns `nil` when the identifier
  is absent from the feed.
- `YouTubeAggregator.refetch` builds the same content shape as `aggregate()` for a known video ID
  (using an injected `YouTubeClient`); `nil` on unparseable URL.
- `RedditAggregator.refetch` + `RedditClient.fetchPost` decode the post from element 0 and build
  content (using an injected `RedditClient`); `nil` on unparseable permalink.
- `AggregationService.forceReload(article:)` upserts only the current article and never calls the
  feed path; returns 0 (no feed reload) when `refetch` yields `nil`.
