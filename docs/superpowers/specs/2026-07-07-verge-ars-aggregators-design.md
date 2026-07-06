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
| Per-type options | **AI-only** (no extra toggle) | Simplest surface. Empty-element cleanup and page-combining are always-on, not user-configurable. |
| Ars pagination | **Port multi-page combining** | Ars long-form features paginate; page-1-only would truncate them. |
| The Verge pagination | Single-page | The Verge articles are single-page. |

## Archetype

`MerkurAggregator` (single-page) is the template for **The Verge**.
`MactechnewsAggregator` (multi-page combining) is the template for **Ars Technica**.
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

Subclass of `FullWebsiteAggregator`, modeled on `MactechnewsAggregator` (multi-page).

- `static let defaultFeed = "https://arstechnica.com/feed/"`
- `identifierChoices` (all verified 200):
  - `https://arstechnica.com/feed/` — "Main Feed"
  - `https://arstechnica.com/gadgets/feed/` — "Gadgets"
  - `https://arstechnica.com/science/feed/` — "Science"
  - `https://arstechnica.com/gaming/feed/` — "Gaming"
- `contentSelector = ".post-content"` (verified on a live article page).
- `selectorsToRemove` (starting set, refined against fixture): `.ad`, `[class*='ad-wrapper']`,
  `.ad--mid-content`, `.ad--rail`, `aside`, `script`, `style`, `.social-share`, non-YouTube iframes.
- `fetchEntries()` — identifier-or-`defaultFeed` RSS parse.
- **Multi-page combining** — port the MacTechNews `enrich()` + `detectPagination()` +
  `mergeContentDivs()` logic. Combining is **always on** (no toggle). `detectPagination()`
  must handle whichever URL form Ars uses (`?page=N` query param and/or `/N/` path segment);
  the exact markup will be confirmed against a real multi-page fixture during TDD.
- `processFullContent()` — extract `.post-content`, strip noise, always-on empty-element removal,
  embed/image rewrite, sanitize.

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
strip `selectorsToRemove`, combine pages for Ars) → `processFullContent()` (sanitize + format to
HTML) → `BlockParser` at import → `[Block]` body → upsert into SwiftData → timeline.

## Error handling

Inherited from `FullWebsiteAggregator.enrich`: on a page-fetch/parse failure it falls back to the
RSS summary (still localizing images); on cancellation it rethrows so a partial run does not persist
feed-only content masquerading as a full scrape. Ars's ported multi-page `enrich` keeps the same
try/catch fallback shape as MacTechNews (missing additional pages degrade to the pages fetched).

## Testing

Swift Testing, inline HTML fixtures (no external fixture files), stubbing `fetchEntries` /
`fetchArticleHTML` — mirroring `MerkurAggregatorTests` / `MactechnewsAggregatorTests`:

- `TheVergeAggregatorTests.swift` — extracts `.duet--article--article-body-component` body,
  strips a noise selector, `identifierChoices` count/first-value.
- `ArsTechnicaAggregatorTests.swift` — extracts `.post-content`, strips an `.ad*` selector,
  **combines two stubbed pages into one body**, `identifierChoices` = 4 with expected values.
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

The Verge is single-page (correct for that site). Ars page-combining relies on detecting Ars's
current pagination markup; if Ars changes it, long features silently fall back to page 1 (same
failure mode as the other multi-page scrapers). Combining is not user-toggleable.

## Out of scope

- MKBHD / any YouTube source.
- User-configurable toggles beyond the shared AI block.
- The Verge section feeds (site exposes only the main feed).
