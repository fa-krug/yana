# The Verge & Ars Technica Aggregators — Design

**Date:** 2026-07-07
**Status:** Approved design, pending spec review

## Goal

Add two new dedicated managed content sources to Yana's aggregator catalog:

- **The Verge** (`the_verge`) — US tech/culture news
- **Ars Technica** (`ars_technica`) — US tech/science news

Both are **full-article scrapers**: they fetch the site's RSS feed for the article list,
then scrape each article page for the complete body using site-specific CSS selectors —
the same pattern as the existing German scrapers (`heise`, `merkur`, `mactechnews`, …).

MKBHD was considered but **dropped from scope**.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Integration style | Dedicated `AggregatorType` cases | Consistent with the existing curated scraper catalog; each appears by name in the feed-type picker. |
| Content depth | Full-article scraping | Both feeds carry only summaries/excerpts; scraping gives complete bodies. |
| Per-type options | **AI-only** (no extra toggle) | Simplest surface. Empty-element cleanup and block-merging are always-on, not user-configurable. |
| Ars multi-block body | **Merge all in-page `.post-content` blocks** | See correction below — Ars renders the whole article (all "pages") in one fetch as multiple sibling `.post-content` blocks; no extra HTTP fetches needed. |
| The Verge body | First `article-body-component` block only | See correction below — the page embeds many related/stream article bodies; only the first is the main article. |

## Research correction (supersedes the original pagination plan)

The approved design assumed Ars paginates across separate URLs (`?page=N`) and The Verge is a
single body block. Fetching real pages showed otherwise:

- **The Verge** (`verge.html`): the article prose *is* server-rendered, but the page contains
  ~22 `.duet--article--article-body-component` divs — the main article **plus embedded
  related/"stream" article bodies**. `HTMLUtils.extractMainContent` already takes `.first()`,
  which is the main article. **Merging would be wrong** (it would splice in unrelated articles).
  → The Verge is a plain single-block Merkur-style subclass; no special extraction.
- **Ars Technica** (`ars.html`, `feat.html`): appending `/N/` to an article redirects to a
  `#page-N` **anchor on the same URL**. The page's own metadata (`pagination_pages_tot: 3`)
  confirms multi-page features, but **every "page" is present in the single fetched HTML** as
  sibling `div.post-content.post-content-double` blocks separated by `<a data-page="N">`
  trackers. Even a single-page news article splits into 2 genuine (non-duplicate) `.post-content`
  blocks. `extractMainContent` takes only `.first()` → it would **truncate** the article.
  → Ars overrides extraction to **select and merge all `div.post-content` blocks from the one
  fetched page**. No `fetchAdditionalPage`, no `detectPagination`, no extra network calls.

This is strictly simpler than the originally-specced MacTechNews multi-fetch port, needs no
pagination-markup guessing, and still yields complete long-form article bodies.

## Archetype

`MerkurAggregator` (single-block extraction) is the template for **The Verge** and the base shape
for **Ars Technica**; Ars additionally overrides extraction to merge all in-page `.post-content`
blocks (see the research correction above).
Both subclass `FullWebsiteAggregator`, which already provides the fetch → extract-by-selector →
header-hoist → image-download → sanitize pipeline. A scraper only overrides
`contentSelector`, `selectorsToRemove`, `fetchEntries()`, and (for cleanup/pagination)
`processFullContent()` / `enrich()`.

## Components

### 1. `TheVergeAggregator` (new — `Yana/Aggregators/Concrete/TheVergeAggregator.swift`)

Subclass of `FullWebsiteAggregator`, modeled on `MerkurAggregator`.

- `static let defaultFeed = "https://www.theverge.com/rss/index.xml"` — the only feed The
  Verge exposes (section feeds under `/<cat>/rss/index.xml` return 404, verified).
- `static let identifierChoices = [("https://www.theverge.com/rss/index.xml", "Main Feed")]`
- `contentSelector = ".duet--article--article-body-component"` — The Verge is now WordPress-backed
  with the Vox "Duet" design system; this is the stable article-body container. The real prose
  lives in `.duet--article--dangerously-set-cms-markup` blocks inside it (kept by extracting the
  parent container).
- `selectorsToRemove` (starting set, refined against a captured fixture during TDD): ad slots,
  newsletter/recirculation cards, `aside`, `script`, `style`, and
  `iframe:not([src*='youtube.com']):not([src*='youtu.be'])`. Candidate Duet noise classes:
  `[class*='duet--recirculation']`, `[class*='duet--ad']`, `[class*='newsletter']`.
- `fetchEntries()` — identifier-or-`defaultFeed` RSS parse (verbatim Merkur).
- `processFullContent()` — Merkur-style: always-on empty-element removal (`p`/`div`/`span`),
  embed rewrite, header-image dedup, image rewrite, sanitize.

### 2. `ArsTechnicaAggregator` (new — `Yana/Aggregators/Concrete/ArsTechnicaAggregator.swift`)

Subclass of `FullWebsiteAggregator`, modeled on `MerkurAggregator` but with a custom
**in-page multi-block merge** (no extra HTTP fetches).

- `static let defaultFeed = "https://arstechnica.com/feed/"`
- `identifierChoices` (all verified 200):
  - `https://arstechnica.com/feed/` — "Main Feed"
  - `https://arstechnica.com/gadgets/feed/` — "Gadgets"
  - `https://arstechnica.com/science/feed/` — "Science"
  - `https://arstechnica.com/gaming/feed/` — "Gaming"
- `contentSelector = ".post-content"` (verified on live article pages).
- `selectorsToRemove` (starting set, refined against fixture): `.ad`, `[class*='ad-wrapper']`,
  `.ad--mid-content`, `.ad--rail`, `aside`, `script`, `style`, `.social-share`, non-YouTube iframes.
- `fetchEntries()` — identifier-or-`defaultFeed` RSS parse.
- **In-page block merge** — override `enrich()` (or a `mergedContentHTML` extraction step) to
  select **all** `div.post-content` blocks in the single fetched page and concatenate their inner
  HTML in document order (wrapped in one container), *then* run `processFullContent`. This is
  required because a single fetch already contains every "page" as sibling `.post-content` blocks,
  and the base `extractMainContent` keeps only `.first()`. No `fetchAdditionalPage` /
  `detectPagination`. Do not de-duplicate blocks — they are distinct article segments.
- `processFullContent()` — strip noise, always-on empty-element removal, embed/image rewrite,
  sanitize (Merkur-style).

### 3. `AggregatorType` (`Yana/Aggregators/AggregatorType.swift`)

- Add `case theVerge = "the_verge"` and `case arsTechnica = "ars_technica"`.
- `displayName`: `"The Verge"`, `"Ars Technica"` (plain brand strings — not localized, matching
  the existing `displayName` convention).
- `brandSiteURL`: `"https://www.theverge.com/"`, `"https://arstechnica.com/"` (favicon → feed logo).
- `identifierChoices`: delegate to `TheVergeAggregator.identifierChoices` / `ArsTechnicaAggregator.identifierChoices`.
- `defaultOptions`: `.theVerge(TheVergeOptions())` / `.arsTechnica(ArsTechnicaOptions())`.
- `identifierKind`: no change — both fall through to the `.url` default.

### 4. `AggregatorOptions` (`Yana/Models/AggregatorOptions.swift`)

- New structs (AI-only):
  ```swift
  struct TheVergeOptions: Codable, Sendable, Equatable { var ai = AIOptions() }
  struct ArsTechnicaOptions: Codable, Sendable, Equatable { var ai = AIOptions() }
  ```
- Add `case theVerge(TheVergeOptions)` / `case arsTechnica(ArsTechnicaOptions)` to the enum.
- Add both to the `ai` computed-property switch.
- **Add forward/backward-compatible `init(from:)` decoding extensions** for both structs.
  This is mandatory: per the documented pattern in that file, SwiftData's composite decoder
  **traps (EXC_BREAKPOINT), not throws**, on a missing key, so every field must be decoded with
  `decodeIfPresent`. (Even AI-only structs follow this to stay safe when fields are added later.)

### 5. `AggregatorRegistry` (`Yana/Aggregators/AggregatorRegistry.swift`)

- Add `.theVerge, .arsTechnica` to the news-scraper group in `makeAggregator(_:credentials:)`
  and to `makeNewsScraper(...)` returning the two new aggregators. The `switch` is exhaustive,
  so omitting a case is a compile error.

### 6. Options UI (`Yana/Views/Config/AggregatorOptionsForm.swift`)

- In the `body` switch: `case .theVerge`, `case .arsTechnica` → `EmptyView()` (AI-only, like
  `.feedContent`).
- In the `aiBinding` set-switch: add both cases so the shared AI block writes back correctly.

## Data flow

Unchanged from existing scrapers: `AggregationService.update(feed:)` →
`AggregatorRegistry.makeAggregator` → `TheVerge/ArsTechnicaAggregator.aggregate()` →
`fetchEntries()` (RSS list) → per-entry `enrich()` (scrape page, extract `contentSelector`,
strip `selectorsToRemove`; for Ars, merge all in-page `.post-content` blocks first) →
`processFullContent()` (sanitize + format to HTML) → `BlockParser` at import → `[Block]` body →
upsert into SwiftData → timeline.

## Error handling

Inherited from `FullWebsiteAggregator.enrich`: on a page-fetch/parse failure it falls back to the
RSS summary (still localizing images); on cancellation it rethrows so a partial run does not persist
feed-only content masquerading as a full scrape. Ars's overridden `enrich` keeps the same
try/catch fallback shape; the block-merge happens after the single page fetch, so there are no
additional fetches that can partially fail.

## Testing

Swift Testing, inline HTML fixtures (no external fixture files), stubbing `fetchEntries` /
`fetchArticleHTML` — mirroring `MerkurAggregatorTests` / `MactechnewsAggregatorTests`:

- `TheVergeAggregatorTests.swift` — extracts `.duet--article--article-body-component` body,
  strips a noise selector, `identifierChoices` count/first-value.
- `ArsTechnicaAggregatorTests.swift` — **merges two sibling `.post-content` blocks from one
  fetched page into one body** (proves no truncation), strips an `.ad*` selector,
  `identifierChoices` = 4 with expected values.
- Bump `AggregatorTypeTests`: `AggregatorType.allCases.count == 14` → `16`; add `displayName` /
  `brandSiteURL` expectations for both.
- Extend `AggregatorRegistryScrapersTests` — both types resolve to their concrete aggregator.
- Extend `AggregatorOptionsTests` — enum round-trips; **decoding an options blob missing the `ai`
  key does not crash** and falls back to defaults (guards the SwiftData trap).

## Build / project

New `.swift` files are picked up automatically by XcodeGen folder globbing (`sources: - path: Yana`
and `- path: YanaTests`). Run `xcodegen generate` before building. No `project.yml` edit.

## Translations

**None required.** Brand `displayName`s and `identifierChoices` labels follow the existing
non-localized plain-string convention, and the picker/section labels reuse keys already in
`Localizable.xcstrings` ("Main Feed", "Options", the AI toggles). This will be verified during
implementation; any label that turns out to be new gets a German (`de`) `"translated"` entry.

## Known limitation

The Verge extraction keeps the first `article-body-component` block; if The Verge ever reorders
the DOM so a related/stream body precedes the main article, extraction would grab the wrong one
(low risk — the main article is first today). Ars merges all `.post-content` blocks in the fetched
page; if Ars renders unrelated `.post-content` blocks (e.g. related-story teasers) outside the
main article region, the merge would include them — mitigated by scoping the selector to the main
article container during TDD if the fixture shows stray blocks. Neither behavior is user-toggleable.

## Out of scope

- MKBHD / any YouTube source.
- User-configurable toggles beyond the shared AI block.
- The Verge section feeds (site exposes only the main feed).
