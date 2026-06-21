# Plan: Custom Script Feeds (AI-authored, JavaScript)

Let users build their own feeds with a small JavaScript that produces articles from
**any** source (HTML scrape, JSON/GraphQL API, RSS transform). Scripts are authored by an
**AI editor** — the user writes a plain-language brief and taps **Try**; the app generates
the script, runs it, and previews the first article. The generated JS is editable by hand
for the rare tweak. Scripts are **data-only**: they emit raw article fields and the existing
trusted aggregation pipeline does all sanitization, image caching, embed rewriting, AI
post-processing, dedup, and capping — so a buggy or hostile script cannot bypass any safety
rail.

This is a design + implementation plan. It records the decisions reached during design and
the build order; treat the named reference files as ground truth for existing idioms.

## Global Constraints

- **Swift 6 strict concurrency.** UI/SwiftData code is `@MainActor`. Never pass a
  `ModelContext`, `@Model` instance (`Feed`, `Article`, `Tag`), or `AppSettings` across an
  actor boundary. The script engine runs off the main actor and exchanges only `Sendable`
  value types (`FeedConfig`, `AggregatedArticle`, strings).
- **No new third-party dependencies.** JavaScriptCore is a first-party system framework
  (`import JavaScriptCore`). HTML parsing stays on the existing SwiftSoup via `HTMLUtils`.
- **All user-facing strings must be localizable.** Add every new string to
  `Yana/Resources/Localizable.xcstrings` with a `de` translation marked
  `"state" : "translated"` (German: Apple style, infinitive for actions, no "Du"/"Sie").
- **Match surrounding style.** Follow the patterns in the named reference files (doc
  comments on types, template-method overrides, `@State`/`@Query` usage).
- **Tests must pass.** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`.
- **Reuse, don't re-implement.** The script does the source-specific 80%; the trusted Swift
  pipeline does the dangerous/standardizing 20% exactly as it does for every other feed.

---

## Design decisions (settled)

| Decision | Choice | Rationale |
|---|---|---|
| Script power | **Data-only** — emit raw article fields, pipeline finishes | A script can't bypass sanitization, image caching, or leak remote URLs into the reader |
| Engine | **JavaScriptCore** (first-party) | No dependency; familiar language; `JSContextGroupSetExecutionTimeLimit` gives a real CPU watchdog |
| Source | **Source-agnostic** (HTML, JSON API, RSS, GraphQL…) | HTML scraping is just one recipe; JSON APIs are likely the common case |
| Output | **`Yana.emit(article)` streaming** (array return as sugar) | Per-article processing, early-stop at the daily cap, low memory, natural pagination |
| Authoring | **AI editor** (prompt + Try → preview), reusing app AI settings | The only way to produce a script; no native plugin code (App Store 2.5.2) |
| Secrets | **Per-feed secret in Keychain**, exposed as `input.secret` | Never travels with exported script source |
| Availability | **Only when AI is configured** | Authoring is AI-driven; runtime is not (see edge cases) |
| Distribution | **Local export/import as editable source** | User-authored & viewable; safe under App Store guideline 2.5.2 |

### App Store guideline 2.5.2

The feature stays inside the well-trodden carve-out (Scriptable, Pythonista, JSBox, …): the
code is **user-authored and viewable/editable**, runs in an **interpreter sandbox**, and only
configures existing functionality (producing feed articles) — it does not download code that
adds app features or commerce. Sharing is **import-as-editable-source the user reviews**,
never silent auto-install.

---

## The script contract

The script defines one entry point, `run(input)`, and emits articles. It may also `return`
an array as sugar for trivial cases.

```js
function run(input) {
  // input.url    = the feed's seed identifier (FeedConfig.identifier)
  // input.secret = per-feed Keychain secret, or "" if none set
  const data = JSON.parse(Yana.httpGet(input.url, {
    headers: { Authorization: "Bearer " + input.secret }
  }));
  for (const p of data.items) {
    Yana.emit({
      title:  p.headline,
      url:    p.permalink,                  // dedup identifier within the feed
      date:   Yana.parseDate(p.published_at),
      author: p.author?.name ?? "",
      html:   p.body_html ?? p.summary      // RAW — pipeline sanitizes & caches images
    });
  }
}
```

Emitted object → `AggregatedArticle` mapping (`Yana/Aggregators/AggregatedArticle.swift`):

| Emit field | Maps to | Notes |
|---|---|---|
| `title` | `title` | required; entry dropped if missing |
| `url` | `url` + `identifier` | required; `identifier` defaults to `url` |
| `html` | `rawContent` | optional; pipeline sanitizes into `content` |
| `date` | `date` | `Date` (epoch ms or ISO string accepted) |
| `author` | `author` | optional |
| `iconURL` | `iconURL` | optional |

Output is **validated and clamped** before entering the pipeline (drop entries missing
title/url, cap count) — identical to how built-in aggregators are bounded.

---

## The `Yana.*` API surface (the only globals scripts can touch)

| API | Backed by | Notes |
|---|---|---|
| `Yana.emit(article)` | engine | Core output primitive; in preview mode the engine stops after the **first** emit |
| `Yana.httpGet(url, options?)` → string | `HTTPClient.fetchHTML`/`fetchData` | Any content type; `options` = `{ method, headers, body }`; same UA / 25 MB cap / retry-backoff |
| `Yana.select(html, css)` → nodes | `SwiftSoup` via `HTMLUtils.parse` | `.text() / .attr(name) / .html()`; optional HTML helper |
| `Yana.parseFeed(xml)` → entries | `FeedParser.parse` | RSS/Atom/RDF; optional RSS helper |
| `Yana.parseDate(str)` → Date | `FeedParser.parseDate` | 7 formats + ISO 8601 |
| `Yana.log(...)` | console capture | Surfaced in the test/preview panel |

JSON needs no helper — JavaScriptCore has native `JSON.parse`/`JSON.stringify`.

### Sandbox & resource limits

- **Network only via `Yana.httpGet`** — no `XMLHttpRequest`/`fetch`/`WebSocket`. Optionally
  reject `file://`, loopback, and private-IP hosts (cheap SSRF hygiene).
- **No filesystem, no Keychain access, no cross-feed data, no remote `eval`.**
- **CPU watchdog** via `JSContextGroupSetExecutionTimeLimit` (~10–15 s).
- `httpGet` blocks on the underlying Swift `async` fetch via a semaphore so scripts read as
  straight-line synchronous code (no promises/await to learn). The engine therefore runs on a
  background thread, never the main actor.

---

## The AI editor (prompt + Try → preview)

The editor screen is, top to bottom: **a prompt field → a Try button → an article preview
(or an error + log)**. The generated JS lives underneath, hidden behind an **"Edit script"**
disclosure that most users never open.

**On Try:**
1. Take the prompt + the feed's seed URL (+ secret if set).
2. **Generate** the script via `AIClient` (reusing the app's configured AI provider/key).
3. **Run** it in the sandbox in **preview mode** — cancel the moment the first `Yana.emit`
   fires. One article is enough to prove the path.
4. **Show** that article rendered the way the reader will (run it through the real
   sanitize/image/embed pipeline), so Try validates script → pipeline → reader end-to-end.
5. On failure (generation or first run), **capped self-heal**: feed the error + `Yana.log`
   back for 1–2 corrective passes. Only if it still fails do we surface the error + log.
6. Save the generated JS to `CustomScriptOptions.source`.

### Two-pass, content-type-aware authoring (invisible plumbing)

The user never sees this; it's how generation reliably nails selectors/field mappings for
both the list and the item:

1. App fetches the **seed** at design time (`HTTPClient`) → reduces to a model-friendly
   sample → AI writes the *listing* step (produces item URLs/IDs).
   - **HTML** → DOM skeleton (strip `script`/`style`/`svg`/comments via SwiftSoup; keep tags
     + `id`/`class` + truncated text).
   - **JSON** → pretty-printed + truncated shape (keys/nesting).
   - **XML/RSS** → trimmed sample.
2. App runs that step to discover one real item, fetches the **detail** resource → reduces →
   AI writes the *field/content extraction*.
3. Combine → preview-run → capped self-heal → editable result.

The **authoring-time** fetch is done by the app and is throwaway (only to show the model the
real shape). At **runtime** the script does its own fetching. Different moments, different
fetchers — this resolves the "but the script is what fetches the data" chicken-and-egg.

### Bundled base instructions (single source of truth)

A versioned, bundled prompt documents the `run(input)` contract, the `Yana.*` API, the emit
shape, the sandbox limits, and **one worked example per source type** (HTML scrape, JSON API,
RSS transform). The same document is the contract the runtime enforces, so the model can't
hallucinate APIs that don't exist.

---

## Availability gating

- `AggregatorType.customScript` is **filtered out of the feed-type picker unless AI is
  configured** (a provider with a valid key, or Apple Intelligence available on-device).
  Add an `AppSettings.isAIConfigured` helper so the picker and editor share one check.
- When AI isn't configured, show the entry **disabled with a hint** —
  "Configure AI in Settings to create custom feeds" (localized) — rather than hiding it, so
  users discover *why* it's unavailable.
- **Authoring needs AI; runtime does not.** A finished script runs in pure JavaScriptCore.
  So configure-AI → create feed → remove-AI leaves the feed fetching normally; only the
  AI-dependent controls (Try / regenerate) disable, while manual **Edit script** still works.
  New custom-script feeds just can't be added until AI is reconfigured.

---

## Integration footprint (matches existing patterns)

1. **`Yana/Aggregators/AggregatorType.swift`** — add `case customScript`
   (`identifierKind = .url`, `requiredAPIKey = .none`, a `displayName`, `defaultOptions`).
2. **`Yana/Models/AggregatorOptions.swift`** — add `case customScript(CustomScriptOptions)`
   and `struct CustomScriptOptions: Codable, Sendable { var source = ""; var prompt = ""; var ai = AIOptions() }`.
   (`prompt` is stored so the user can re-run/refine the brief later.)
3. **`Yana/Services/ScriptEngine.swift`** (new) — JavaScriptCore wrapper: builds the
   `JSContext`, installs the `Yana.*` bridge, enforces the time limit, runs on a background
   thread, supports a `previewMode` that throws a sentinel to stop after the first emit.
4. **`Yana/Services/ScriptGenerator.swift`** (new) — wraps `AIClient`; implements the
   two-pass authoring, the content-type-aware sample reducer, and the capped self-heal loop.
5. **`Yana/Aggregators/Concrete/CustomScriptAggregator.swift`** (new) —
   `final class CustomScriptAggregator: FullWebsiteAggregator`; overrides `fetchEntries()`
   (and/or `enrich`) to run the script through `ScriptEngine`, mapping emitted objects to
   `AggregatedArticle`s. Per-article `refetch` re-runs the script for one identifier (single
   item reload, consistent with the project's reload semantics).
6. **`Yana/Aggregators/AggregatorRegistry.swift`** — wire `case .customScript` to
   `CustomScriptAggregator`; thread the Keychain secret in via `AggregatorCredentials`.
7. **`Yana/Services/KeychainService.swift`** — store/read the per-feed script secret.
8. **Editor UI** (new view under `Yana/Views/`) — prompt field + **Try** + article preview +
   **Edit script** disclosure; reachable from the feed create/edit flow when AI is configured.
9. **`AppSettings`** — `isAIConfigured` helper.
10. **`Yana/Resources/Localizable.xcstrings`** — all new strings + `de` translations.

> New source files under existing globs are picked up automatically; only touch `project.yml`
> / run `xcodegen` if a build shows a file isn't included.

---

## Build order (suggested)

1. **Types & wiring** — `AggregatorType.customScript`, `CustomScriptOptions`, registry stub
   returning an empty result. Build green.
2. **`ScriptEngine`** + `Yana.*` bridge + time limit + preview-mode first-emit stop. Unit-test
   with inline scripts (no network): emit mapping, validation/clamping, timeout, preview stop.
3. **`CustomScriptAggregator`** over the pipeline; test that emitted `html` is sanitized,
   images cached to `yana-img://`, dedup/cap applied. Per-article `refetch`.
4. **`ScriptGenerator`** — sample reducer (HTML/JSON/XML), two-pass authoring, self-heal.
   Test the reducer deterministically; mock `AIClient`.
5. **Editor UI** — prompt + Try + preview + Edit-script; availability gating.
6. **Secrets** — Keychain store + `input.secret` injection; ensure export omits secrets.
7. **Export/import** — editable source (and optional OPML `yana:` extension), secrets excluded.
8. **Localization pass** — backfill every new string with `de`.

---

## Tests (new files under `YanaTests/`)

- `ScriptEngineTests.swift` — emit→`AggregatedArticle` mapping; missing-field drops; array
  return sugar; `JSON.parse` path; `Yana.parseDate`/`Yana.select` helpers; execution-time
  limit; preview-mode stops after first emit; sandbox (no `fetch`/FS).
- `CustomScriptAggregatorTests.swift` — emitted raw `html` is sanitized; images rewritten to
  `yana-img://`; dedup by identifier; daily cap / intake window honored; `refetch` re-runs one
  item; failure isolation.
- `ScriptGeneratorTests.swift` — sample reducer output (HTML skeleton, JSON shape) is bounded
  and structure-preserving; self-heal stops after the cap (mocked `AIClient`).
- Gating — `isAIConfigured` controls `customScript` availability.

## Open / deferred

- Exact wording of the bundled base-instruction prompt (iterate against real sites).
- Whether to expose a tiny `Yana.cache` for cross-run de-dup hints (defer; pipeline already
  dedups by identifier).
- Community gallery / sharing beyond local export (explicitly deferred for App Store safety).
