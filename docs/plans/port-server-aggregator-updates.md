# Plan: Port server aggregator updates to iOS

Port aggregator-logic changes from the `../Yana` Python server (commits up to
`4a17759`) into the iOS Swift app. Each task mirrors a specific server commit.
The server repo is at `/Users/skrug/PycharmProjects/Yana` and is the ground
truth for behavior; the iOS app reimplements the same behavior in Swift idioms.

## Global Constraints

- **Swift 6 strict concurrency**: keep `@MainActor` annotations consistent with
  surrounding code; network calls are `async`.
- **Mirror existing iOS idioms**, not Python structure. Use SwiftSoup parsing
  via `HTMLUtils.parse`, the existing `HTTPClient` for network/JSON, and follow
  the patterns already in the named reference files. Do NOT introduce new
  dependencies.
- **Tests**: each aggregator has a test file under `YanaTests/` (e.g.
  `MeinMmoAggregatorTests.swift`, `RedditAggregatorTests.swift`,
  `MactechnewsAggregatorTests.swift`, `HeiseAggregatorTests.swift`,
  `HeaderElementExtractorTests.swift`). Add/extend tests using the Swift Testing
  framework (`import Testing`, `@MainActor`). Follow the existing test style.
- **Translations**: any NEW user-facing string shown in the app UI must be added
  to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked
  `"state" : "translated"` (per CLAUDE.md). Note: HTML embedded into article
  *content* (rendered in the web view) is NOT app UI — match the server's
  in-HTML English labels for those, exactly as the existing Twitter/X embed in
  `EmbedRewriter.swift` does.
- **Build/verify**: prefer running the relevant test target. Full build:
  `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`.
  If the simulator/build is unavailable in the sandbox, say so explicitly and
  show the test code + reasoning instead of claiming a green build.
- Do not run `xcodegen generate` unless you add a new source file; if you add a
  file, confirm it lands in a directory already globbed by `project.yml` (the
  `Yana/Aggregators/...` tree is) so no project regeneration is needed.

## Task 1 — Heise: case-insensitive title skip filter

**Server commit:** `338e62a` ("heise: Make title filter case-insensitive").
**iOS file:** `Yana/Aggregators/Concrete/HeiseAggregator.swift`.

The title skip-list check (`shouldInclude`, ~lines 54-56) currently does
case-sensitive `article.title.contains($0)`. The skip list contains
`"die Bilder der Woche"` (lowercase) but real titles read "Die Bilder der
Woche". Make the match case-insensitive: lowercase the title once and compare
against lowercased skip terms.

**Tests:** extend `HeiseAggregatorTests.swift` — assert an article titled
"Die Bilder der Woche 1234" is excluded, and a normal title is included.

## Task 2 — MeinMMO: refresh selectors for redesigned layout

**Server commits:** `818952b` (new-layout selectors), `cbc0ad1`
(wp-block-mmo-hub-box removal), `1e3afd3` (dailymotion-embed-container removal).
**iOS file:** `Yana/Aggregators/Concrete/MeinMmoAggregator.swift`.

Read `git -C /Users/skrug/PycharmProjects/Yana show 818952b cbc0ad1 1e3afd3` for
exact selectors. The content selector (`div.entry-content`) is already ported
(iOS commit `28afe68`); the rest is NOT. Apply:

1. **Pagination** (~lines 83-99): replace the stale container/link/span
   selectors with the new layout — container `div.page-links`, page links
   `a.post-page-numbers`, current-page spans `span.post-page-numbers`. Keep the
   existing "search inside content div, then fall back to whole document"
   structure and the existing page-URL construction.
2. **`selectorsToRemove`** (~lines 24-28): add `div.sources-wrapper`,
   `div.feedback-box`, `div.page-links` (new removals from `818952b`);
   `div.wp-block-mmo-hub-box` (from `cbc0ad1`); `.dailymotion-embed-container`
   (from `1e3afd3`). Remove now-stale entries that `818952b` dropped
   (`ul.page-numbers`, `.post-page-numbers`, `#ftwp-container-outer`) — verify
   against the server diff which exact stale entries were removed; keep any iOS
   entry that has no server counterpart and is still valid.
3. **Header image**: `818952b` updates header-image extraction to
   `img.wp-post-image` inside `div.post-thumbnail` (fallback: first
   `img.wp-post-image`). Check how iOS currently derives the MeinMMO header
   image (`MeinMmoAggregator.swift` + `HeaderElementExtractor.swift`). If iOS
   relies on the old `img[width=16][height=9]` / `div#gp-page-header-inner`
   path, update it to the new selectors. If iOS already derives the header a
   different way that still works on the new layout, document that and skip.

**Tests:** extend `MeinMmoAggregatorTests.swift` — pagination detection against
new-layout HTML (`div.page-links`/`a.post-page-numbers`), and removal of the
three new junk containers. Reuse/adapt any HTML fixtures already in the test.

## Task 3 — MeinMMO: inline Bluesky embeds

**Server commit:** `39cadd5` ("Add inline Bluesky embeds to mein_mmo").
**Server files:** `core/aggregators/utils/bluesky.py`,
`core/aggregators/mein_mmo/embed_processors.py` (the `BlueskyEmbedProcessor`),
`core/tests/test_bluesky_embed.py`. Read all three.
**iOS files:** new `Yana/Aggregators/Utils/BlueskyEmbed.swift` (or extend
`EmbedRewriter.swift`), and wire it into the MeinMMO figure-embed chain
(`EmbedRewriter.swift` / `MeinMmoAggregator.swift` — find where Twitter/X
figures are converted).

Mirror the existing Twitter/X embed path in `EmbedRewriter.swift` exactly:
detect `bsky.app` post links in `<figure>` elements, resolve the handle→DID and
fetch the post via the public Bluesky API
(`public.api.bsky.app/xrpc/...resolveHandle` then `app.bsky.feed.getPosts`)
using the existing `HTTPClient` JSON helper, then build a styled blockquote
embed (author display name + `@handle`, post text, images, engagement
stats/date, "View on Bluesky" link) matching the server's
`build_bluesky_embed_html` output. Insert the Bluesky branch into the figure
strategy chain in the same position as the server (after Twitter/X, before
Reddit). On any network/parse failure, leave the figure unchanged (graceful
fallback), same as the existing embeds.

In-HTML labels stay English to match the server output (this is article
content, not app UI — no xcstrings entries needed).

**Tests:** add a `BlueskyEmbed`-focused test (mirror `test_bluesky_embed.py`):
URL parsing/detection, image extraction from a sample post JSON, and embed-HTML
rendering. Network calls must be exercised via the same seam the existing embed
tests use (inspect `EmbedRewriterTests.swift` for how Twitter/X embedding is
tested without live network); follow that approach.

## Task 4 — Reddit: embed Twitter/X from selftext as header

**Server commit:** `9ce1a0f` ("embed Twitter/X posts from selftext instead of
extracting wrong images"); server file `core/aggregators/reddit/images.py`.
**iOS file:** `Yana/Aggregators/Concrete/RedditAggregator.swift`
(`headerImageURL(for:)`, ~lines 154-182).

Add an early "Priority 0.6" check in `headerImageURL(for:)`: scan
`post.selftext` for URLs, and if a Twitter/X status URL is present, return it
(so the downstream embed path renders the tweet) BEFORE the gallery/preview/
thumbnail checks. Also ensure Twitter/X URLs found in selftext are NOT passed to
plain image extraction (server skips them in
`_extract_image_url_from_selftext`). Find the iOS equivalent of selftext image
extraction and apply the same skip. Mirror the server's Twitter/X URL detection
(hosts `twitter.com`/`x.com` with a `/status/` path).

**Tests:** extend `RedditAggregatorTests.swift` — a self-post whose selftext
contains `https://x.com/u/status/123` yields that URL as the header (not a
preview/thumbnail), and a self-post with a plain image link still behaves as
before.

## Task 5 — Mactechnews: multi-page combining + comment extraction

**Server commits:** `ef3ef79` (multipage + comments), `4099b10` (current-page
`<strong>N</strong>` detection + type fix). Server files:
`core/aggregators/mactechnews/{aggregator.py,comment_extractor.py,multipage_handler.py}`
and `core/tests/test_mactechnews_aggregator.py`. Read them.
**iOS file:** `Yana/Aggregators/Concrete/MactechnewsAggregator.swift`.
**Options already exist** in `Yana/Models/AggregatorOptions.swift`
(`MactechnewsOptions`: `combinePages`, `includeComments`, `maxComments`) — wire
them in; do NOT add new options.
**Reference patterns (mirror these iOS idioms):**
`MeinMmoAggregator.swift` for multi-page detect/fetch/merge,
`HeiseAggregator.swift` for comment extraction/formatting and the
`ContentFormatter.format(..., commentsHTML:)` call.

Implement:
1. Pagination detection for `?page=N` (and `&page=N`) query params, PLUS
   current page rendered as `<strong>N</strong>` (the `4099b10` fix). Always
   include page 1.
2. Multi-page fetch + content-div merge when `combinePages` is on, mirroring
   `MeinMmoAggregator`'s enrich/merge flow.
3. Comment extraction when `includeComments` is on, capped at `maxComments`:
   container `div.MtnCommentScroll`, each comment `div.MtnComment`, author
   `span.MtnCommentAccountName`, timestamp `span.MtnCommentTime`, text
   `div.MtnCommentText`, anchor from the comment element `id`. Mirror Heise's
   comment HTML shape and pass via `ContentFormatter.format(commentsHTML:)`.

In-HTML labels (e.g. "Comments") follow the existing Heise iOS aggregator's
convention — match whatever Heise does (localized vs. literal); do not invent a
new convention.

**Tests:** extend `MactechnewsAggregatorTests.swift` — pagination detection
(links + `<strong>` current page), `combinePages` merging two pages, and comment
extraction respecting `maxComments`. Add a multipage HTML fixture analogous to
the server's `mactechnews_multipage.html` if the test style uses fixtures.

## Task 6 — URL-based image overrides for all aggregators

**Server commit:** `72deb75`; server file
`core/aggregators/services/image_extraction/domain_overrides.py` and its callers.
**iOS files:** new `Yana/Aggregators/Utils/DomainImageOverrides.swift`; wire into
`Yana/Aggregators/Utils/HeaderElementExtractor.swift` and
`Yana/Aggregators/Concrete/RedditAggregator.swift` (`headerImageURL(for:)`).

Create `DomainImageOverrides` with a `[prefix: imageURL]` map and a
longest-prefix-wins lookup (`overrideImageURL(for url:)`). Seed with the
server's mapping (`https://en-americas-support.nintendo.com/` → the Wikipedia
Nintendo image; copy the exact image URL from the server file). Integrate as the
highest-priority short-circuit:
1. In `HeaderElementExtractor`, before its existing strategies, if an override
   matches the article URL, build the header element from the override image.
2. In `RedditAggregator.headerImageURL(for:)`, before all existing checks,
   return the override if `post.url` matches.

Ordering note vs. Task 4: in `headerImageURL(for:)` the override check is the
very first thing; the Task 4 selftext-Twitter/X check follows. If Task 4 is
already merged when this runs, place the override check ABOVE it. If this task
runs first, place it first and Task 4 slots in after.

**Tests:** extend `HeaderElementExtractorTests.swift` (or add a
`DomainImageOverridesTests.swift`) — longest-prefix-wins lookup, no-match
returns nil, and a matching article URL produces the override header.

## Notes / explicitly NOT ported

- `d4cbe07` (Reddit `min_age_hours`) — already fully ported on iOS.
- `91ee1c7` (Python requests ISO-8859-1 charset default bug) — N/A: iOS
  `HTTPClient` already decodes UTF-8 first with ISO-8859-1 only as fallback, so
  the bug does not exist. No change.
- Server-only commits (ruff/mypy style fixes, SQLite `BEGIN IMMEDIATE` locking)
  have no iOS analogue.
