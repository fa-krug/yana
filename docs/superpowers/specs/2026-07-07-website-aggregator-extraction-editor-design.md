# Full Website Aggregator — Feedless Ingestion & Extraction Editor

## Overview

Advance the `fullWebsite` aggregator on two fronts:

1. **Feedless ingestion** — accept a plain homepage URL as the identifier and auto-discover
   its RSS/Atom feed, so users no longer have to hunt down the feed URL themselves.
2. **Extraction editor** — replace the two single-line selector text fields with a richer
   editor: two editable selector lists (content + ignore) on their own sub-pages, an
   AI button that regenerates both lists from the live page, and a preview sub-page that
   renders the first three articles in the app's native `[Block]` format so users see the
   real result before saving.

Everything composes onto the existing `RSSPipelineAggregator` → `FullWebsiteAggregator`
hook structure; no aggregator rewrite.

## Decisions (locked)

- **Feedless = feed auto-discovery only** (option 1a). When the identifier is an HTML page
  rather than a feed, discover the `<link rel="alternate" type="application/rss+xml|atom+xml">`
  feed and use it. No AI-proposed link selector, no homepage link-scraping in this version.
- **Content selectors combine with OR** — the union of every element matching any content
  selector is kept (to gather content distributed across several containers), with nested
  matches de-duplicated (keep the outermost).
- **Ignore selectors combine with OR** — remove every element matching any ignore selector.
- **Legacy selectors are not enforced.** Existing `customContentSelector` /
  `customSelectorsToRemove` values are passed to the AI generation step as *candidates to
  validate*, not migrated into the active lists.
- **AI button overwrites** both lists (with confirmation).
- **Layout:** the feed editor gets three `NavigationLink`s — Content Selectors, Ignore
  Selectors, Preview. Only the **Preview** screen has a top tab bar, switching between the
  first three previewed articles. Preview has a **reload** button in its toolbar.

## Data model

`WebsiteOptions` (in `Yana/Models/AggregatorOptions.swift`) changes:

```swift
struct WebsiteOptions: Codable, Sendable, Equatable {
    var useFullContent = true
    var contentSelectors: [String] = []      // was: customContentSelector: String
    var ignoreSelectors: [String] = []       // was: customSelectorsToRemove: String
    var ai = AIOptions()

    // Custom Decodable: if the new arrays are absent but the legacy single-string
    // fields are present, seed the arrays from them (comma-split) so existing feeds
    // keep working. Legacy keys are decode-only; we never re-encode them.
    private enum CodingKeys: String, CodingKey { case useFullContent, contentSelectors, ignoreSelectors, ai }
    private enum LegacyKeys: String, CodingKey { case customContentSelector, customSelectorsToRemove }
}
```

Options are persisted as a SwiftData composite attribute, so adding fields with defaults is
migration-safe; the custom `init(from:)` handles the one-time legacy fallback in-place.

## Extraction pipeline changes

### `HTMLUtils.extractMainContent`

Today it takes one `selector` and uses `doc.select(selector).first()`. New signature takes a
**list** of content selectors and unions matches:

```swift
static func extractMainContent(_ html: String,
                               contentSelectors: [String],
                               removeSelectors: [String]) throws -> String
```

- Gather `doc.select(sel)` for every content selector, in document order.
- Drop any matched element contained within another matched element (keep outermost) so
  nested overlaps aren't duplicated.
- Fall back to `doc.body()` when nothing matches (unchanged behavior).
- Concatenate the surviving elements' HTML into one container, then apply the ignore
  selectors (remove every match of every ignore selector) to that container.

### `FullWebsiteAggregator`

- `contentSelector` default becomes the array
  `["article", ".article-content", ".entry-content", "main"]` (was the comma group). OR-union
  now means a page with sibling matches gathers all of them — intended for "distributed
  content"; nested `main > article` still collapses to the outer via the dedup rule.
- `enrich` reads `opts.contentSelectors` (falling back to the default array when empty) and
  `opts.ignoreSelectors` (appended to the base `selectorsToRemove`), then calls the new
  `extractMainContent`. `processFullContent` is unchanged — the output still flows through
  `EmbedRewriter` → sanitization → `rewriteImages` → `ContentFormatter.format`, which is what
  `BlockParser` later turns into `[Block]`s.

## Feed auto-discovery (feedless)

New pure-ish helper `FeedDiscovery`:

```swift
enum FeedDiscovery {
    /// Fetch `pageURL`, return the first alternate RSS/Atom feed href (resolved absolute), or nil.
    static func discoverFeedURL(from pageURL: URL) async throws -> URL?
}
```

- Parse `<link rel="alternate" type="application/rss+xml">` and `…/atom+xml` via SwiftSoup;
  resolve relative hrefs against `pageURL`; prefer RSS, then Atom.

Wire into `RSSPipelineAggregator.fetchEntries()` (or override in `FullWebsiteAggregator`):
try to parse `config.identifier` as a feed; if it yields **no entries** (or fails as a feed)
and the identifier is an HTML page, run `discoverFeedURL`, then parse the discovered feed.
Keep it best-effort — a page with neither a feed nor a discoverable one surfaces the existing
"no entries" outcome. (Caching the discovered URL is out of scope for v1; discovery re-runs
per fetch.)

## UI

### Feed editor (`FeedEditorView` / `AggregatorOptionsForm`)

For the `.fullWebsite` case, replace the inline `websiteSection`'s two text fields with:

- The existing **Fetch Full Content** toggle (kept inline).
- `NavigationLink` **Content Selectors** → `SelectorListView(kind: .content)`
- `NavigationLink` **Ignore Selectors** → `SelectorListView(kind: .ignore)`
- `NavigationLink` **Preview** → `ExtractionPreviewView`

Each link shows a count subtitle (e.g. "4 selectors").

### `SelectorListView`

An editable `[String]` list (following the `ManagedList` pattern, minus `@Query` — the source
is the bound options array):

- Rows are editable text fields; swipe / edit-mode delete; add-row button.
- Toolbar **Auto-generate with AI** action (see below). Overwrites *this feed's* content and
  ignore lists after a confirmation dialog. Disabled with an explanatory footer when no AI
  provider is configured.
- Empty state via `ContentUnavailableView`.

### AI auto-generate

New `SelectorSuggester` service using the existing `AIClient`:

```swift
struct SelectorSuggestion: Codable { var contentSelectors: [String]; var ignoreSelectors: [String] }
```

- Fetch the feed's first article page HTML, chrome-strip + cap via `ArticleAIText`.
- Prompt (JSON mode) asks for `{contentSelectors, ignoreSelectors}` — CSS selectors for the
  main article container(s) and the noise to strip — and passes the current/legacy selectors
  as candidates to validate and keep only if still present/appropriate.
- `AIClient.generate(prompt:jsonMode:true)`, decode `SelectorSuggestion`, overwrite both lists.

### `ExtractionPreviewView`

- Builds a transient `FeedConfig` from the in-progress editor state (memberwise init;
  `dailyLimit = 3`) — no SwiftData write.
- Runs the aggregator's `aggregate()` (which does **not** persist), takes the first three
  `AggregatedArticle`s.
- Renders each via `BlockParser.blocks(fromHTML:baseURL:)` → `ArticleBlockView` — the exact
  native `[Block]` "optimized format" the reader uses.
- Top tab bar (segmented `Picker` / `TabView`) switches between article 1 / 2 / 3.
- Toolbar **reload** button re-runs the fetch + extraction with the current selectors, so the
  user can iterate: tweak selectors → reload → see the block output.
- Loading / empty / error states inline.

## Testing

- `HTMLUtils.extractMainContent` OR-union + nested-dedup; ignore-OR removal.
- `WebsiteOptions` legacy-decode fallback (old single-string keys → arrays).
- `FeedDiscovery.discoverFeedURL` from fixture HTML (rss, atom, none, relative href).
- `FullWebsiteAggregator` feedless path (identifier is homepage → discovered feed → entries).
- `SelectorSuggester` JSON decode (mock `AIClient`).
- Existing `FullWebsiteAggregatorTests` updated for the new selector-list options.

## Localization

Every new user-facing string (section titles, link labels, "Auto-generate with AI", the
confirmation dialog, empty states, preview tab/reload labels, the no-AI-provider footer) gets
`en` + `de` entries in `Localizable.xcstrings`, marked `translated`.

## Out of scope (this version)

- Homepage link-scraping / AI link selector for sites with no discoverable feed.
- Readability-style density scoring (a strong follow-up to the OR-union selectors).
- JSON-LD `articleBody` extraction, multi-page stitching, conditional GET — separate items
  from the earlier idea list.
