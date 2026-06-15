# Local Aggregator — Phase 4 Parity Design (On-Device Aggregation Engine)

## Overview

Phase 4 replaces the stub `AggregationService` and the empty aggregator implementations with
a real **on-device** aggregation engine that ports the [Yana server](../../../../Yana)
aggregators (`core/aggregators/`) faithfully — fetch, parse, clean, enrich, AI-process,
dedup, persist — adjusted only where a serverless phone genuinely differs from a Django
server.

This document is the authoritative parity reference: it records the server behavior that
must be reproduced, and every deliberate divergence (with the reason). It supersedes the
Phase 4 section of `2026-06-15-local-aggregator-design.md` and the high-level
`plans/2026-06-15-local-aggregator-phase4-aggregation.md` roadmap, which remain valid for
the task groupings (4a–4g).

**Reference:** server source at `/Users/skrug/PycharmProjects/Yana/core/aggregators/` (and
`core/ai_client.py`, `core/views/default.py`, `core/models.py`). Port **behavior**, not code.

## Guiding principle

Reproduce the server's *output* — the exact article HTML shape, the same selectors, the same
per-aggregator quirks — so a feed configured identically yields equivalent articles. Diverge
only for: (1) things that physically cannot exist on a phone (the server's own proxy/auth
crutches), and (2) four product decisions recorded below.

## Product decisions (resolved in brainstorming)

1. **Hybrid dates.** `Article.date` holds the real publish date (for display). The timeline
   sorts by **import time** (`Article.createdAt`) descending, and position-memory anchors on
   `createdAt` — matching the server's import-ordered feel. We do **not** rewrite dates to
   `now()±30s`. The server's "drop articles older than 60 days" becomes a pure **intake
   filter** on publish date (does not mutate the date).
2. **Flat run cap.** Each run fetches up to `runLimit = max(0, feed.dailyLimit −
   collectedToday)`; `collectedToday` counts the feed's articles with `createdAt >=
   startOfToday`. The server's adaptive time-of-day quota (`get_current_run_limit`) is **not**
   ported — it is tuned for a cron running many times a day, which a phone never does.
3. **All images downloaded; no remote image URLs.** Every `<img>` (body images, header image,
   comic image, podcast artwork, Reddit/YouTube thumbnails) is fetched on-device, compressed,
   and stored in a **local file cache** keyed by content hash. Image `src` attributes are
   rewritten to a custom scheme (`yana-img://<hash>`) served by a `WKURLSchemeHandler`. Bytes
   live as files (not base64 in `content`) to keep the SwiftData store lean and dedup shared
   images; cache cleanup is tied to retention. The only base64 path is Oglaf's explicit
   `convertToBase64` option, preserved as-is.
4. **Embeds go direct (no server proxy) but reproduce the proxy's exact markup.** See §3.5.
5. **AI failure drops the article** (server parity): on AI error or unparseable JSON the
   article is skipped entirely, never entering the timeline.

## 1. Aggregator architecture — port the template-method pipeline

The server's `BaseAggregator` is a Template Method; every aggregator overrides specific hooks
and most scrapers inherit `FullWebsiteAggregator → RssAggregator → BaseAggregator`. We
reproduce this as a Swift class hierarchy that runs **off the main actor**.

### Class hierarchy

- `BaseAggregator` (open class, `Sendable`, **not** `@MainActor`) — defines the pipeline and
  default hooks. Pipeline (mirrors `rss.py: aggregate()` generalized to base):
  1. `validate()`
  2. `runLimit()` → `Int` (flat cap, §2)
  3. `fetchSourceData(limit:)`
  4. `parseToRawArticles(_:)`
  5. `filterArticles(_:)`  — default: drop publish date < now−60d (no date rewrite)
  6. `enrichArticles(_:)`  — default: identity
  7. `finalizeArticles(_:)` — default: AI post-processing (§5)
  Returns `[AggregatedArticle]`.
- `RssAggregator: BaseAggregator` — `fetchSourceData` parses the feed; `parseToRawArticles`
  maps entries (title/link/summary/published/author).
- `FullWebsiteAggregator: RssAggregator` — `enrichArticles` fetches each article URL, extracts
  the header element, `extractContent`, `processContent`. Exposes `selectorsToRemove`,
  `contentSelector`, and reads `useFullContent` / `customContentSelector` /
  `customSelectorsToRemove`.
- Each scraper subclasses the appropriate parent and overrides only its hooks.

### Concurrency & data flow

- The service runs on `@MainActor`. For each feed it builds a **`Sendable` snapshot**
  (`FeedConfig`: `identifier`, `dailyLimit`, typed `AggregatorOptions`, `collectedTodayCount`,
  `tags` as value data, and resolved `AggregatorCredentials`) — aggregators never reference a
  SwiftData `Feed`/`ModelContext`.
- Aggregators run in detached/background tasks and return `[AggregatedArticle]` (already
  `Sendable`). The service performs all upserts/deletes back on `@MainActor`.
- Bounded concurrency across feeds (task group capped ~3–4). One feed throwing is isolated:
  its error is recorded to `feed.lastError`; the run continues.

### `Aggregator` protocol → base class

The current `protocol Aggregator` (validate + aggregate) is replaced by the base-class
pipeline above. `AggregatorRegistry` maps `AggregatorType → (FeedConfig) -> BaseAggregator`.
`AggregatedArticle` gains a `headerImageURL: String?` and a `comments`/extra fields only if a
hook needs to thread data through stages (kept minimal; prefer carrying state in a private
per-run dictionary like the server's article dicts).

## 2. Orchestration — `AggregationService`

Public API unchanged: `updateAll()`, `update(feed:)`, `update(article:)`; `isUpdating` state.

- **Run limit (flat):** `runLimit = max(0, dailyLimit − collectedToday)`, where
  `collectedToday = count(feed.articles where createdAt >= startOfToday)`. If 0, skip the feed.
- **Upsert / dedup** by `(feed, identifier)`:
  - Insert: create `Article`; `tags = feed.tags` (snapshot); `createdAt = .now`;
    `date = aggregated.date` (publish date).
  - Update: refresh `title`/`rawContent`/`content`/`author`/`iconURL`; recompute
    `tags = feed.tags` **+ Starred if currently present**; **do not** change `createdAt`
    (preserves timeline position) — `date` may refresh to the source's publish date.
- **Intake age filter:** discard aggregated articles whose publish `date` < now − 60 days
  (server `filter_articles` parity, minus the date rewrite).
- **Retention cleanup:** after a run, delete `Article`s with `createdAt` < now −
  `AppSettings.retentionDays` (default 30) **except** those tagged Starred. Delete their
  cached images (§3.4).
- **`update(article:)`:** rebuild the owning aggregator, re-fetch + re-process that single
  article (re-running enrich/finalize incl. AI), re-upsert. Triggered by pull-down on the
  reader (current article) alongside `updateAll()`.
- **`lastFetchedAt` / `lastError`** set per feed.

## 3. Shared foundation (the utils layer)

Ports `core/aggregators/utils/` and `services/header_element/`. New `Yana/Aggregators/Utils/`.

### 3.1 HTML parsing — SwiftSoup

Add **SwiftSoup** as an SPM dependency (`project.yml` `packages` + target dependency). It is
the BeautifulSoup analogue used by every HTML utility below.

### 3.2 HTML utilities (mirror server names/behavior)

- `cleanHTML(_:)` — strip HTML comments.
- `sanitizeClassNames(_:)` — rewrite every `class` → `data-sanitized-class` (avoids reader CSS
  collisions; the reader stylesheet targets `data-sanitized-class="article-content"` etc.).
- `removeEmptyElements(_:tags:)` — drop empty `<p>/<div>/<span>` with no text and no media.
- `extractMainContent(html:selector:removeSelectors:)` — `select_one(selector)` with body
  fallback, then `decompose()` each remove-selector.
- `removeImageByURL(_:url:)` — remove first matching `<img>` by exact / filename / responsive
  variant (port `_get_base_filename` regexes: strip `-\d+x\d+`/`-\d+` and `-[a-zA-Z0-9]{3,6}`
  hash suffixes; skip generic names; check `src`/`data-src`/`data-lazy-src`).
- `proxyYouTubeEmbeds`/`proxyDailymotion` → **rewriteEmbeds** (§3.5).
- Default `FullWebsiteAggregator.selectorsToRemove` and `contentSelector` ported verbatim.

### 3.3 `formatArticleContent` — the article HTML wrapper

Reproduce the server's exact output shape (`content_formatter.py`):

```html
<header style="margin-bottom: 1.5em; text-align: center;">
  <img src="yana-img://<hash>" alt="{title}" style="max-width: 100%; height: auto; border-radius: 8px;">
  {optional header caption}
</header>
<section data-sanitized-class="article-content">{content}</section>
<section data-sanitized-class="article-comments">{comments}</section>   <!-- optional -->
<footer><p>Source: <a href="{url}" target="_blank" rel="noopener">{url}</a></p></footer>
```

Header variants: image (above), YouTube embed (§3.5), or Twitter/X blockquote
(`build_tweet_embed_html` via fxtwitter, ported). Parts joined by `\n\n`.

### 3.4 Networking + image pipeline

- `fetchHTML(url:timeout:)` — Mozilla UA, 30s, exponential-backoff (1/2/4s) over 3 attempts,
  `ArticleSkipError` on 4xx (skips the article), other errors keep original content.
- `parseFeed(url:)` — RSS/Atom parser replacing feedparser: entry `content` (list) → `summary`
  → `description` fallback; `enclosures`; `itunes:*` (duration, image); date parsing
  (RFC822 + ISO/Atom); `bozo`-style validation.
- **Image cache + custom scheme:**
  - `ImageStore` actor: `store(url:) async -> hash?` downloads (Mozilla UA, MIME whitelist,
    min-size guard), compresses via **ImageIO** (header images max ~1200px; WEBP if available
    else JPEG q≈0.9; preserve PNG transparency), writes `<caches>/images/<hash>.<ext>`, returns
    a stable content hash. Dedups by hash.
  - `rewriteImages(in:)` walks all `<img>` (incl. `data-src`/lazy), downloads via `ImageStore`,
    rewrites `src` → `yana-img://<hash>`, drops unresolved images.
  - `ImageSchemeHandler: WKURLSchemeHandler` resolves `yana-img://<hash>` to the cached file.
  - Retention cleanup removes orphaned cache files (no referencing live article).
- **Header element extraction** (`services/header_element` parity): strategy chain — Reddit
  embed → Reddit post icon → YouTube thumbnail → generic lead image. Result references a
  cached image (`yana-img://`), and the duplicate is removed from the body via
  `removeImageByURL`. (Reddit icon path uses the Reddit API client, §4.3.)

### 3.5 Embed rewriting (direct, proxy-identical markup)

Replace `/api/youtube-proxy` and `/api/dailymotion-proxy` hops with the inner iframe the proxy
would have served (`core/views/default.py`), preserving the container + 16:9 CSS and all
params. The WebView renders article HTML under a fixed base origin (the custom-scheme host);
the `origin` param is set to that base origin (retained per decision) and `enablejsapi=1`.

YouTube (in-content and header):
```html
<div class="youtube-embed-container">
  <iframe src="https://www.youtube-nocookie.com/embed/{id}?autoplay=0&loop=0&mute=0&controls=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1&origin={baseOrigin}"
          width="560" height="315" allowfullscreen
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          referrerpolicy="strict-origin-when-cross-origin"></iframe>
</div>
```
(`loop=1` adds `playlist={id}`.) The container 16:9 CSS (`padding-bottom:56.25%`, the
`max-width:512px` rule) ships in the reader stylesheet.

Dailymotion:
```html
<div class="dailymotion-embed-container">
  <iframe src="https://geo.dailymotion.com/player.html?video={id}" width="560" height="315"
          allowfullscreen allow="autoplay; web-share"
          referrerpolicy="strict-origin-when-cross-origin"></iframe>
</div>
```

Twitter/X via fxtwitter (`api.fxtwitter.com/status/{id}`, direct), Reddit video embeds direct.
Non-whitelisted iframes remain stripped (`sanitize_html_attributes` parity).

## 4. Per-aggregator port

Every aggregator gets fixture-based tests (captured RSS/HTML/API responses as bundle
resources; **no live network in CI**) and fails gracefully per feed.

### 4.1 Generic

- **`feedContent`** (`RssAggregator`): use entry content as-is (content→summary→description),
  `proxyYouTubeEmbeds`, `sanitizeClassNames`, `cleanHTML`, `formatArticleContent` (footer only,
  no header image). No full-article fetch.
- **`fullWebsite`** (`FullWebsiteAggregator`): `useFullContent` gate; default content selector
  `article, .article-content, .entry-content, main`; default remove list (script/style/ad/etc.,
  YouTube iframes preserved); `customContentSelector` / `customSelectorsToRemove` (comma-split).

### 4.2 Site scrapers (all `FullWebsiteAggregator`)

| Scraper | Key specifics to port |
|---|---|
| **Heise** | `seite=all` multi-page fetch; content `#meldung, .StoryContent`; full remove-list; title skip-list ("die Bilder der Woche", "Produktwerker", "heise-Angebot", "#TGIQF", "heise+", "#heiseshow:", "Mein Scrum ist kaputt", "software-architektur.tv", "Developer Snapshots"); content skip "Event Sourcing"; empty-element removal; **forum comments** via JSON-LD `discussionUrl` → fallback forum links → comment selectors (`li.posting_element`, `[id^=posting_]`, `.posting`, `.a-comment`) rendered as blockquotes, capped at `maxComments` (default 5), gated by `includeComments`. Feed picker (4 feeds). |
| **Merkur** | content `.idjs-Story`; full remove-list; optional `removeEmptyElements`; sanitize then strip `data-sanitized-*`. Regional feed picker (18). |
| **Tagesschau** | `textabsatz`-class `<p>` + `trenner`-class `<h2>` only, skipping teaser/bigfive/accordion/related containers; HTML5 media-header extraction from `div[data-v-type=MediaPlayer]` (audio/video, poster, embed code); skip livestreams (title "Livestream:") and videos (URLs) per options; skip-list ("tagesschau","tagesthemen","11KM-Podcast","Podcast 15 Minuten","15 Minuten:") and `bilder/blickpunkte`. Feed picker (42). |
| **Caschy** | content `.entry-inner`; remove `.aawp*`; skip `(Anzeige)` and "Immer wieder sonntags KW"; iframe whitelist (YouTube + Twitter/X); resolve relative URLs; dedup first image. Single feed `stadt-bremerhaven.de/feed/`. |
| **MacTechNews** | forced feed `mactechnews.de/Rss/News.x`; content `.MtnArticle`; numeric-image-ID dedup (`\.(\d{5,})\.\w+$`); resolve relative URLs; full content forced. No options. |
| **Mein-MMO** | page-combining (`combinePages`): detect pagination (`div.gp-pagination-numbers`, `ul.page-numbers`, etc.), fetch+merge `div.gp-entry-content`; embed-processor strategies (YouTube/Twitter/Reddit/TikTok/YouTube-fallback); Dailymotion block → direct embed (§3.5); remove "Weiter geht es auf Seite" markers + recirculation/affiliate blocks. Single feed. |

### 4.3 Social / media (own raw API clients; keys from Keychain)

- **Reddit** (`BaseAggregator`): **application-only OAuth** replacing PRAW — POST
  `https://www.reddit.com/api/v1/access_token` (grant `client_credentials`, HTTP Basic
  client_id/secret, `User-Agent` = `redditUserAgent`) → bearer token; then
  `https://oauth.reddit.com/r/{sub}/{sort}.json` (sort hot/new/top/rising) and
  `/comments/{id}.json`. Port: filter AutoModerator + age + `minComments`; comments sorted
  "best", bot/deleted filtering, capped at `commentLimit`, blockquote markup; galleries,
  crossposts, link/image/video handling; header image (gallery/direct/thumbnail/link-page) via
  the image pipeline; markdown→HTML for selftext/comments (port a minimal Reddit-markdown
  converter). `includeHeaderImage`. **Live subreddit search** (`/subreddits/search`) for the
  editor identifier picker.
- **YouTube** (`BaseAggregator`): Data API v3 (key from Keychain) —
  `search`/`channels`/`playlistItems`/`videos`/`commentThreads`. Resolve channel id/handle →
  uploads playlist → video details (thumbnail priority maxres→high→medium); comments
  `order=relevance&textFormat=html` capped at `commentLimit`; description `\n`→`<br>`; embed
  via §3.5 prepended. **Live channel search** for the editor picker.
- **Podcast** (`RssAggregator`): enclosure pick (audio MIME / .mp3/.m4a/.ogg/.opus/.wav),
  duration parse (HH:MM:SS / MM:SS / seconds), artwork (`itunes_image`/`media_thumbnail`) sized
  to `artworkSize` (via image pipeline). Markup: artwork `<div>`, HTML5 `<audio controls>`
  (gated by `includePlayer`), duration + download link (gated by `includeDownloadLink`), show
  notes. (Native AVPlayer is a later enhancement — out of scope.)

## 5. AI post-processing

Port `base.py::_apply_ai_processing` + `core/ai_client.py`. New `Yana/Services/AIClient.swift`.

- Gate: any of `summarize`/`improveWriting`/`translate` on **and** `AppSettings.activeAIProvider`
  set. Strip `header/footer/nav/script/style`; build the JSON-mode prompt (exact instruction
  text ported, incl. preserve-HTML/links and translate-but-not-link-labels rules); per-article
  `aiRequestDelay`.
- **Providers:** OpenAI (`{openaiAPIURL}/chat/completions`, Bearer, `response_format` json),
  Anthropic (`api.anthropic.com/v1/messages`, `x-api-key` + `anthropic-version: 2023-06-01`,
  `content[0].text`), Gemini (`…/{model}:generateContent?key=`, `responseMimeType` +
  `responseSchema`, uppercase schema types). Temperature/maxTokens from `AppSettings`.
- **Retry/timeout:** exponential backoff on 429 only, `aiMaxRetries`/`aiRetryDelay` with total
  time budget; `aiRequestTimeout`; non-429 errors fail immediately.
- **Robust JSON extraction** (direct parse → ```` ```json ```` block → first `{`…last `}`).
- **Drop article on failure / invalid JSON** (decision 5).
- **Model lists:** maintained in iOS code with **current** model ids (server lists are stale).
  Daily/monthly limits stored but unenforced (server parity).

## 6. Background refresh

`BGAppRefreshTask` id `de.fa-krug.Yana.background-refresh`, registered in `Info-iOS.plist`
`BGTaskSchedulerPermittedIdentifiers` + `project.yml`. Handler builds the service, runs
`updateAll()`, reschedules at `AppSettings.backgroundInterval`, first scheduled on launch.
Best-effort; errors silent. Pull-down remains the primary trigger.

## 7. Reader & model adjustments (carried into Phase 4)

- Timeline `@Query` sorts by `createdAt` desc (was `date`); position-memory anchor keyed on
  `createdAt` (+ identifier). Update Phase 3 helpers accordingly.
- `WKWebView` gains the `ImageSchemeHandler` for `yana-img://`, the embed container CSS, and a
  fixed base origin used by `formatArticleContent`/embeds.
- `AggregatedArticle` may carry `headerImageURL`/transient enrichment fields needed across
  hooks.

## 8. Decomposition into detailed plans (→ writing-plans)

Each becomes its own TDD plan producing working, tested software:

- **4a — Orchestration core:** service (updateAll/update(feed:)/update(article:)),
  FeedConfig snapshot, run cap + collectedToday, upsert/dedup/tag-snapshot, intake age filter,
  retention cleanup, credential resolution. Tested with a fake aggregator (no network).
- **4b — Foundation:** SwiftSoup dep, HTTP fetch, RSS/Atom parser, HTML utils,
  `formatArticleContent`, image pipeline + `ImageStore` + `WKURLSchemeHandler`, embed
  rewriting, header-element strategies. Fixture-tested.
- **4c — Generic aggregators:** `feedContent`, `fullWebsite`.
- **4d — Site scrapers:** Heise, Merkur, Tagesschau, Caschy, MacTechNews, Mein-MMO (may split).
- **4e — Social/media:** Reddit (OAuth client + search), YouTube (Data API + search), Podcast.
- **4f — AI post-processing:** `AIClient` (3 providers), prompt/JSON/drop logic, knobs, model
  lists; wired into `finalizeArticles` + `update(article:)`.
- **4g — Background refresh:** `BGAppRefreshTask` wiring.

## Definition of Done (Phase 4)

`updateAll()`/`update(feed:)`/`update(article:)` populate SwiftData from real sources with
dedup, flat run cap, intake filter, retention, on-device image caching, and proxy-identical
embeds — green fixture-backed tests for at least `feedContent` + `fullWebsite` (4a–4c).
Remaining families (4d–4f) and background refresh (4g) land incrementally in their own plans,
each fixture-tested with graceful per-feed failure.

## Out of scope (Phase 4)

- Native AVPlayer for podcasts (HTML5 `<audio>` for now).
- Live network in tests (fixtures/replay only).
- The server's GReader API surface, usage-limit enforcement, and any multi-user concerns.
