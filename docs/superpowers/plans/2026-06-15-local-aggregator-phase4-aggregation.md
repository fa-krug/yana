# Local Aggregator — Phase 4 (Aggregation Engine) High-Level Plan

> **Status:** High-level roadmap, NOT a bite-sized implementation plan. Feed this into the
> `superpowers:writing-plans` skill (with the spec) to generate detailed TDD plans when
> Phase 4 begins. This phase is large — expect to split it into **several** detailed plans
> (one per task grouping below), each producing working, testable software.
>
> **Spec:** `docs/superpowers/specs/2026-06-15-local-aggregator-design.md`
> **Reference:** the Yana server aggregators at `../Yana/core/aggregators/` — port behavior,
> not code. Each Yana aggregator's `aggregate()` returns the same dict shape our
> `AggregatedArticle` mirrors.
> **Depends on:** Phases 1–3 complete and merged (models, config hub, timeline reader).

**Goal:** Replace the stub `AggregationService` and empty `AggregatorRegistry` with a real
on-device aggregation engine — fetch, parse, process, dedup, persist — plus force-update at
all three granularities and best-effort background refresh.

**Architecture:** Each `AggregatorType` gets a concrete `Aggregator` returning
`[AggregatedArticle]`. `AggregationService` orchestrates: resolve credentials → build
aggregator via registry → `validate()` → `aggregate()` → upsert into SwiftData (dedup by
`(feed, identifier)`, snapshot the feed's tags onto each article, preserve the Starred tag)
→ enforce `dailyLimit` → optional AI post-processing → set `lastFetchedAt`/`lastError`.
Networking off the main actor; SwiftData writes on `@MainActor`. There is **no read/unread
state**.

---

## Task Groupings (each → its own detailed TDD plan)

### 4a. Orchestration core (do first)

- **`AggregationService` real implementation:** `updateAll()`, `update(feed:)`,
  `update(article:)`. Concurrency model (sequential per feed vs. bounded parallel), error
  isolation (one feed's failure doesn't abort the run), `isUpdating` state.
- **Upsert + dedup:** look up `Article` by `(feed, identifier)`. On **insert**, set
  `article.tags = feed.tags` (snapshot). On **update**, refresh content and recompute tags as
  `feed.tags` **plus the Starred tag if the article currently carries it** — feed-derived tags
  re-snapshot while the user's star survives. Pure, heavily unit-tested.
- **Daily limit + retention cleanup:** cap new articles per run at `Feed.dailyLimit`;
  delete articles older than `AppSettings.retentionDays` (by `date`) **except** those tagged
  Starred. (No read state — age is the only cleanup criterion besides Starred.)
- **Credential resolution:** read API keys from Keychain into `AggregatorCredentials`.
- Test the whole orchestration against a fake `Aggregator` returning canned
  `AggregatedArticle`s (no network) — this is where most correctness lives.

### 4b. Networking + HTML utilities (shared foundation)

- Async HTTP fetch wrapper (timeouts, user-agent, error mapping to `AggregatorError`).
- HTML parsing/sanitizing utility (pick a Swift HTML parser, e.g. SwiftSoup) for
  content-selector extraction and element removal — mirrors Yana's BeautifulSoup usage
  (`custom_content_selector`, `custom_selectors_to_remove`, `remove_empty_elements`).
- Date parsing helpers (RSS/Atom date formats).
- Test parsing/sanitizing against fixture HTML; no live network in tests.

### 4c. Generic aggregators (highest value)

- **`feedContent` (RSS/Atom):** parse feed XML → entries; use the entry content as-is (no
  full-article fetch — matches the server's `FeedContentAggregator`). Test against fixture
  RSS + Atom files.
- **`fullWebsite`:** fetch page, extract article content via selectors (`useFullContent`,
  `customContentSelector`, `customSelectorsToRemove`). Test against fixture HTML.

### 4d. Managed site-specific scrapers

Port from `../Yana/core/aggregators/{heise,merkur,tagesschau,explosm,dark_legacy,
caschys_blog,mactechnews,oglaf,mein_mmo}`. Each reads its own typed options struct
(`HeiseOptions.includeComments`, `TagesschauOptions.skipVideos`, `OglafOptions.showAltText`/
`convertToBase64`, etc.) — see the spec's options table. One detailed plan can batch several;
each aggregator tested against captured fixture pages. **Flag:** scrapers are fragile and
break when sites change — include fixture-based tests and graceful per-feed failure.

### 4e. Social / media aggregators (need API keys)

- **`reddit`:** Reddit API (OAuth via stored client id/secret + `redditUserAgent`); honor
  `subredditSort`, `minComments`, `commentLimit`, `includeHeaderImage`, `minAgeHours`.
- **`youtube`:** YouTube Data API (stored key); honor `commentLimit`.
- **`podcast`:** podcast RSS + enclosures; honor `includePlayer`, `includeDownloadLink`,
  `artworkSize`.
- Test with recorded API responses; surface missing-key errors via
  `AggregatorError.missingAPIKey`.

### 4f. AI post-processing

- AI client abstraction over OpenAI / Anthropic / Gemini (active provider + key + model +
  OpenAI URL from `AppSettings`/Keychain). Apply per-feed `AIOptions`: `summarize`,
  `improveWriting`, `translate(translateLanguage)` — mirrors
  `../Yana/core/aggregators/base.py` lines ~290–360.
- Honor the AI knobs in `AppSettings`: `aiTemperature`, `aiMaxTokens`, `aiMaxPromptLength`,
  `aiDefaultDailyLimit`, `aiDefaultMonthlyLimit`, `aiRequestTimeout`, `aiMaxRetries`,
  `aiRetryDelay`, `aiRequestDelay`.
- Rate-limit/delay handling; per-article failure non-fatal.
- Wired into the orchestration step after upsert; `update(article:)` re-runs it.

### 4g. Background refresh

- `BGAppRefreshTask` (identifier `de.fa-krug.Yana.background-refresh`), registered in
  `Info-iOS.plist` `BGTaskSchedulerPermittedIdentifiers` and `project.yml`.
- Handler builds `AggregationService`, runs `updateAll()`, reschedules at
  `AppSettings.backgroundInterval`. First task scheduled on launch. Silent errors.
- Per the spec, background execution is best-effort; force-update is the primary trigger.

## Cross-Cutting Decisions (resolve in detailed planning)

- **HTML parser dependency:** SwiftSoup vs. hand-rolled `XMLParser`-based extraction.
  Adding an SPM dependency requires a `project.yml` `packages`/`dependencies` change.
- **Concurrency:** how many feeds aggregate concurrently; keep SwiftData writes on
  `@MainActor`, networking/parsing off it (actors or detached tasks + `Sendable` DTOs).
- **Testing network:** fixture/replay strategy (no live calls in CI); capture real
  responses once, store as bundle resources.
- **Icons:** whether to download/store `iconURL` images now or defer.

## Definition of Done (Phase 4)

`updateAll()`/`update(feed:)`/`update(article:)` populate SwiftData from real sources for at
least `feedContent` + `fullWebsite` (4a–4c), with dedup, daily-limit, retention, and
fixture-backed tests green; remaining aggregator families (4d–4f) and background refresh
(4g) land incrementally in their own plans.
