# Native Block Rendering (Retire HTML Articles)

**Date:** 2026-06-29
**Status:** Draft (design)

## Problem

Article bodies are stored as sanitized HTML strings (`Article.content`) and
rendered in a per-page `WKWebView` themed by NetNewsWire `.nnwtheme` CSS bundles
(`ArticleRenderer` → `MacroProcessor` → `ReaderWebViewController`). This works, but:

- **WebView cold-start dominates the reader.** A large amount of machinery exists
  *only* to hide WKWebView latency: `ReaderWarmup`, `ReaderWarmupStore`,
  `ReaderWebViewPool`, the off-screen anchor pre-render, and the cross-fade reveal.
- **No native text affordances.** Selection, Dynamic Type, find-in-article, and
  accessibility are whatever WebKit gives us; `ReaderSpeechController` has to scrape
  text back out of the DOM.
- **Look is governed by CSS** fighting source markup (hence `data-sanitized-class`,
  inline-style stripping, 8 theme bundles).
- **Storage is heavy and non-portable** — themed HTML blobs (50KB+ each).

## Goal

Replace HTML-string storage and WebView rendering with a **closed, typed block
model** rendered natively in SwiftUI. Outcomes:

1. **Faster reader** — no WebView in the article body; retire the warmup/pool stack.
2. **Native text features** — `AttributedString` per block ⇒ selection, Dynamic
   Type, accessibility, and clean text for speech, for free.
3. **Consistent look** — native theming (colors/fonts), no CSS.
4. **Smaller, portable storage** — Codable JSON blocks instead of HTML.

## Decisions (locked)

- **Closed block model, no HTML fallback.** Any source node that does not map to a
  known block is **stripped**, not preserved. There is never an inline WebView in
  the body.
- **Drop `Article.rawContent`.** It is dead persistent state — the only stored
  reads are the refetch/summarize seeds in `AggregationService`, and `refetch`
  always repopulates raw content from a fresh network fetch, so the seeded value is
  overwritten. (`AggregatedArticle.rawContent` stays as *transient* pipeline scratch
  used mid-enrich by the Heise/Mactechnews/MeinMmo scrapers; it is simply never
  persisted.)
- **Embeds become thumbnails that open externally.** YouTube/Dailymotion/tweets
  render as a native poster card; tapping opens the provider externally (system
  browser or `SFSafariViewController` per the existing `useSystemBrowser` setting).
  No inline iframe playback.

## Design

### 1. The block model (`Yana/Reader/Block.swift`)

A `Codable, Sendable, Equatable` enum. Inline runs are a separate value type so a
paragraph/heading is a sequence of styled spans.

```swift
enum Block: Codable, Sendable, Equatable {
    case paragraph([InlineRun])
    case heading(level: Int, runs: [InlineRun])   // level 1…6, clamped
    case list(ordered: Bool, items: [[Block]])     // items are block sequences
    case blockquote([Block])
    case image(ref: String, caption: [InlineRun])  // ref is a yana-img://<hash>
    case embed(Embed)                               // poster card → external open
    case codeBlock(text: String, language: String?)
    case divider
}

struct InlineRun: Codable, Sendable, Equatable {
    var text: String
    var styles: Style          // OptionSet: bold, italic, code, strikethrough
    var link: String?          // absolute URL; tap opens externally
}

struct Embed: Codable, Sendable, Equatable {
    enum Provider: String, Codable { case youtube, dailymotion, tweet, generic }
    var provider: Provider
    var thumbnailRef: String?  // yana-img://<hash> if cached, else remote URL, else nil
    var externalURL: String    // where a tap goes
    var title: String?         // e.g. tweet author / video title
}
```

Tables, `<figure>` groupings we don't model, `<form>`, scripts, and anything else
fall through to nothing (stripped).

### 2. Storage change (`Yana/Models/Article.swift`)

- **Remove** `rawContent`.
- **Replace** `content: String` (HTML) with the encoded block array. Store as
  `content: Data` holding JSON-encoded `[Block]` (keeps a single body field; SwiftData
  handles the type change as a property migration — see §7).
- **Add** `plainText: String` — the body flattened to text, derived once at import.
  This is the search surface (replacing today's substring match over HTML) and the
  speech surface. Without it, `ArticleSearch` would match JSON structure noise.
- `summary` stays a `String` (plain text), rendered as its own native block.

`AggregatedArticle` mirrors this: drop the persisted role of `rawContent` (keep the
field as transient scratch), carry `[Block]` + `plainText` instead of `content`.

### 3. HTML → blocks conversion (`Yana/Aggregators/Utils/BlockParser.swift`)

The aggregation pipeline **already** parses every article with SwiftSoup and produces
clean, sanitized HTML (`HTMLUtils.finishSanitization`: images localized to
`yana-img://`, unsafe tags/attrs/styles removed, embeds normalized by
`EmbedRewriter` into YouTube/Dailymotion facades carrying poster URLs). So conversion
is **one new step at the tail of the existing pipeline**, operating on the already-clean
`Document`:

```
fetch → extract → EmbedRewriter → sanitize → localize images
      → BlockParser.blocks(from: Document)   ← NEW: walk DOM, emit [Block]
      → store blocks + derived plainText
```

`BlockParser` walks the body, mapping known tags to blocks and **dropping unknowns**:

- `<p>`, text → `paragraph`; `<h1…h6>` → `heading`; `<ul>/<ol>/<li>` → `list`
- `<blockquote>` → `blockquote` (recurses)
- `<img>` (already a `yana-img://` ref) → `image`, with adjacent `<figcaption>`
- `<pre>/<code>` → `codeBlock`
- `<hr>` → `divider`
- embed facades (`.youtube-embed-container`, `.dailymotion-embed-container`, tweet
  blockquotes) → `embed`, reusing `EmbedRewriter.extractYouTubeID` and the poster
  `<img>` already present in the facade
- inline `<b>/<strong>/<i>/<em>/<code>/<a>` → `InlineRun` styles/links
- everything else (tables, divs we don't recognize, leftover chrome) → recurse into
  children for known blocks, drop the wrapper

This reuses all existing sanitization/image/embed work; only the final emit is new.
The same parser runs on AI "improve writing"/"translate" output (still returned as
HTML — see §6).

**On parser choice (SwiftSoup).** The block walk does **not** add a parse — it reuses
the SwiftSoup `Document` the sanitization pipeline already built, so this redesign adds
no SwiftSoup cost. Dropping SwiftSoup to speed extraction is therefore **out of scope
here**: it is load-bearing across ~17 files (all of `HTMLUtils`, `EmbedRewriter`,
`ImageStore`, `ArticleAIText`, and every CSS-selector-driven scraper — Heise, Merkur,
Mactechnews, MeinMmo, …), and its leniency with malformed real-world HTML is a
correctness feature. If import-time throughput later proves a bottleneck, the real
lever is a **separate, pipeline-wide** migration to a libxml2-backed parser
(Kanna/Fuzi) — meaningfully faster (C vs pure Swift) but behaviorally different on
broken markup and touching every scraper's selectors. Orthogonal lever: **API-driven
sources** (Reddit, YouTube, podcasts) build their HTML from structured data, so they
could emit `[Block]` directly and skip the HTML round-trip entirely — a targeted win
that needs no parser swap.

### 4. Native renderer (`Yana/Reader/ArticleBlockView.swift`)

A SwiftUI `View` that renders `[Block]` top-to-bottom in a `ScrollView`/`LazyVStack`:

- `paragraph`/`heading` → `Text(AttributedString)` built from runs (bold/italic/code,
  links as tappable attributed ranges → external open via `ReaderLinkPolicy`).
- `image` → async load from the local `ImageStore` file for the `yana-img://` ref
  (`AsyncImage`-style, but local — no network), with caption.
- `embed` → poster card (thumbnail + play glyph) → tap opens `externalURL` through
  the existing `ReaderLinkPolicy.openExternally`.
- `list`/`blockquote` → native indented layouts; `codeBlock` → monospaced;
  `divider` → `Divider`.
- The `summary` renders as a styled native block in the same slot it occupies today
  (after the lead image, before the body), preserving the pending/skeleton state.

Theming: native `ArticleTheme` → colors + font choices applied via environment.
Dynamic Type works automatically.

### 5. Reader integration

`ReaderArticleViewController` (the `UIPageViewController` pager) stays — it still
pages between articles, keeps the toolbar, full-screen tap-to-hide, and pull-to-
refresh. Each page swaps its body host: instead of `ReaderWebViewController`
(`WKWebView` + `loadHTMLString`), a `UIHostingController` wrapping `ArticleBlockView`.
Per-page lazy resolution of the full `Article` by `persistentID` is unchanged; the
page now decodes `[Block]` instead of building HTML.

### 6. AI post-processing

`AIProcessor`/`ArticleAIText` still send/receive HTML (summarize, improve, translate
all assume HTML and the prompts insist on preserving tags). Keep that contract: the
AI pass runs on HTML as today, and its HTML output is fed through `BlockParser`
before storage — the same single conversion point. `summary` remains plain text.

### 7. Migration of existing data

`content` changes type (HTML `String` → blocks `Data`) and `rawContent` is removed.
Existing stored articles hold HTML and must be reconverted through `BlockParser`.

**Conversion stays off the cold-start critical path** — this is a hard requirement,
not an optimization. `BlockParser` runs a SwiftSoup parse, which is the exact cost
this redesign removes from the reader; reconverting lazily on first *read* would drag
that parse back onto the anchor's launch path and give the cold-start win back.
Therefore:

- **New articles** are converted at **import time**, in the aggregation pipeline,
  where a SwiftSoup `Document` already exists (the block walk reuses it — no second
  parse). Nothing render-time.
- **Existing articles** are converted by a **one-time background migration sweep**
  (off the launch path), persisting blocks per article; `rawContent` simply drops.
  Retention (~1 month) bounds the set, so the sweep is small and self-clearing.
- The reader's render path **only decodes already-stored `[Block]` JSON** — it never
  parses HTML. An article not yet converted when the reader reaches it renders empty
  (or a lightweight placeholder) until the sweep lands it, rather than parsing inline.

### 8. Retirements

Once the body is native, delete the WebView body stack:
`ReaderWebViewController`, `ReaderWebViewPool`, `ReaderWarmup`/`ReaderWarmupStore`,
`WarmupSlot`, `PrewarmPlan`, `ArticleRenderer`, `MacroProcessor`, the `.nnwtheme`
bundles + `ArticleTheme`/`ArticleThemesManager` CSS plumbing, `page.html`/template/CSS
resources, and the `ReaderWeb` link-interception JS. `ReaderLinkPolicy` is kept (still
governs external opens). This is the bulk of the diff and the bulk of the payoff.

## Phasing

1. **Model + parser, no UI swap.** Add `Block`, `BlockParser`, `plainText`; produce
   and store blocks alongside the existing HTML (dual-write). Unit-test the parser
   against the trickiest sources: Heise (forum comments), Reddit galleries, YouTube,
   tweet blockquotes, podcasts, comics. Repoint `ArticleSearch` at `plainText`.
2. **Native renderer behind a setting.** `ArticleBlockView` + hosting page,
   selectable via a hidden/dev toggle; WebView remains default. Validate visually.
3. **Flip default + migrate.** Native becomes default, lazy reconversion runs, drop
   the HTML `content` write and `rawContent`.
4. **Delete the WebView stack** (§8) and the CSS theme resources.

## Risks / edge cases

- **Tables and complex layouts are dropped** (by decision). Verify the corpus to
  confirm nothing important is table-only; surface in testing if a source relies on
  tables.
- **Inline images / mixed inline content** — runs model text+links; an `<img>` inside
  a `<p>` becomes a separate `image` block (paragraph splits around it).
- **Tweet/embed thumbnails** — fxtwitter blockquotes have no poster; render as a
  text card → external open. Dailymotion/YouTube posters already exist in the facade.
- **Search semantics shift** — from "matches HTML markup" to "matches visible text"
  (`plainText`); strictly better, but results will differ slightly.
- **AI round-trip** — improve/translate output must survive `BlockParser`; covered by
  reusing the one conversion point, but worth a test.

## Touched / new files

- New: `Yana/Reader/Block.swift`, `Yana/Aggregators/Utils/BlockParser.swift`,
  `Yana/Reader/ArticleBlockView.swift`, native `ArticleTheme`.
- Changed: `Yana/Models/Article.swift` (drop `rawContent`, `content`→blocks, add
  `plainText`), `AggregatedArticle.swift`, `ArticleUpsert.swift`,
  `AggregationService.swift` (seed no longer passes `rawContent`), `ArticleSearch.swift`
  (→ `plainText`), `ArticleSummary` (unaffected — already no body), each aggregator's
  enrich tail, `ReaderArticleViewController` (host swap), `ReaderSpeechController`
  (→ `plainText`).
- Deleted (phase 4): the WebView/warmup/theme-CSS stack in §8.
