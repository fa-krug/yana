# Apple Intelligence (on-device) AI provider — Design

**Date:** 2026-06-17
**Status:** Approved (design)
**Scope:** iOS 26 on-device Foundation Models only. Private Cloud Compute and other
WWDC 2026 Foundation Models additions are explicitly **out of scope** — not yet shipping.

## Goal

Add Apple's on-device Foundation Models as a first-class AI post-processing provider
(`AIProvider.appleIntelligence`), alongside the existing OpenAI / Anthropic / Gemini HTTP
providers. It performs the same per-feed tasks (summarize / improveWriting / translate) with
**no API key, no network, no cost**, fitting the app's privacy-first ethos. External
providers stay fully intact; Apple Intelligence is purely additive.

The defining constraint is the on-device model's fixed **~4096-token context window**
(~12–16k characters shared across prompt + article + output), versus the existing pipeline's
50,000-char article cap. Long articles are handled by **chunk + map-reduce**, not truncation.

## Background

Current AI integration (unchanged by this work except where noted):

- `AIProvider` enum (`Models/AppSettings.swift`): `.none/.openai/.anthropic/.gemini`, each
  with a `model` list. API keys in Keychain; provider/model/tuning in `AppSettings`.
- `AIConfig` (`Services/AIClient.swift`): `Sendable` snapshot built on the main actor.
- `AIClient`: HTTP client, `generate(prompt:jsonMode:) async throws -> String` (returns a JSON
  string our prompts ask for).
- `AIProcessor` (`Services/AIProcessor.swift`): `AIProcessing` conformer. Gates on
  `anyEnabled && provider != .none && !apiKey.isEmpty`; strips HTML chrome, caps at 50k chars,
  builds one combined prompt for all enabled tasks, calls `generate`, extracts JSON robustly
  (direct → ```json``` fence → first `{`..last `}`), drops article on failure/invalid JSON.
- Per-feed `AIOptions` (`Models/AggregatorOptions.swift`): `summarize`, `improveWriting`,
  `translate`, `translateLanguage`.
- Pipeline: `aggregate → intake-window filter → daily cap → AIProcessor.process → upsert`.

Device requirement (Apple Intelligence): A17 Pro / iPhone 15 Pro and newer, M-series iPad/Mac,
with Apple Intelligence enabled in Settings. The framework API itself is present on every iOS
26 device; `availability` reports the reason when the model can't run. The project's iOS 26.0
deployment floor means **no `@available` guards are required**.

## Approved decisions

1. **Long articles:** chunk + map-reduce (not truncate, not skip).
2. **Model unavailable (ineligible device / not enabled / downloading):** **passthrough** —
   store the article unmodified — and **surface the status in settings**.
3. **Tasks:** offer all three (summarize, improveWriting, translate), same as external
   providers. Translate quality varies by language but the UI stays consistent.

Per-article *processing failure* (generation error / unusable output) still **drops** the
article, matching the existing processor. Passthrough applies only to model-unavailability.

## Architecture

### Components

| Component | File | Responsibility |
|---|---|---|
| `AIProvider.appleIntelligence` | `Models/AppSettings.swift` | New enum case; `models == []`; no key/URL. |
| `ArticleAIText` (new namespace) | `Services/ArticleAIText.swift` | Shared pure helpers extracted from `AIProcessor`: per-task instruction strings, `stripChrome`, `cap`. Single source of server parity. |
| `AppleIntelligenceClient` | `Services/AppleIntelligenceClient.swift` | Thin `Sendable` wrapper over `FoundationModels`: availability mapping, guided generation, token counting. |
| `AppleIntelligenceProcessor` | `Services/AppleIntelligenceProcessor.swift` | `AIProcessing` conformer: passthrough/drop policy + chunk + map-reduce. |
| Processor factory | `Services/AggregationService.swift` | Selects `AppleIntelligenceProcessor` vs `AIProcessor` by `config.provider`. |
| Settings UI | `Views/Config/SettingsScreenView.swift` | Provider picker entry + availability status row (no key/model fields). |
| Strings | `Resources/Localizable.xcstrings` | Provider name + status messages, `en` + `de`. |

### `ArticleAIText` (shared helpers — targeted refactor)

Extract from `AIProcessor` (which keeps delegating to it, no behavior change for the HTTP path):

- `summarizeInstruction`, `improveWritingInstruction`, `translateInstruction(language:)` —
  the exact server-parity task strings currently inline in `AIProcessor.buildPrompt`.
- `stripChrome(_:) throws -> String` — SwiftSoup removal of header/footer/nav/script/style.
- `cap(_:) -> String` and `maxContentChars = 50_000`.

The HTTP path's JSON-format boilerplate (`return a JSON object with keys 'title'/'content'`,
no markdown fences) stays in `AIProcessor` only — guided generation makes it unnecessary for
the Apple path.

### `AppleIntelligenceClient`

```swift
import FoundationModels

enum AppleIntelligenceAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case notEnabled        // Apple Intelligence off in Settings
    case modelNotReady     // downloading / not yet ready
}

@Generable
struct ProcessedArticle {
    @Guide(description: "The processed article title")
    var title: String
    @Guide(description: "The processed article body as valid HTML, same structure as input")
    var content: String
}

struct AppleIntelligenceClient: Sendable {
    var availability: AppleIntelligenceAvailability { /* map SystemLanguageModel.default.availability */ }

    /// Token count for budgeting (uses model.tokenCount where available, else ~3.5 chars/token heuristic).
    func tokenCount(_ text: String) -> Int

    /// One guided-generation call. Throws on generation failure.
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int)
        async throws -> ProcessedArticle
}
```

- Availability mapping isolates the framework's reason enum so the rest of the app never
  imports it and tests can inject a fake.
- Generation uses `LanguageModelSession(instructions:)` + `respond(to:generating:options:)`
  with `GenerationOptions(temperature:)` and `maximumResponseTokens: maxTokens`.
- No JSON string round-trip: the typed `ProcessedArticle` is consumed directly.

### `AppleIntelligenceProcessor`

`AIProcessing` conformer with an injected client (and, for tests, injectable availability +
generator). Algorithm per article:

1. **Gate:** `anyEnabled && provider == .appleIntelligence`. (No key check for this provider.)
2. **Availability:** if not `.available` → return all input **unchanged (passthrough)**;
   do not call the model.
3. Empty content → keep unchanged (server parity), no call.
4. `stripChrome` + `cap` (shared helpers).
5. **Chunk:** split the cleaned HTML on **top-level block boundaries** (SwiftSoup child nodes)
   into chunks whose token count fits `contextBudget` = window − reserve(instructions + output).
   A single block larger than the budget is itself hard-split by characters as a fallback.
6. **Map:** run each chunk through the combined task instructions (built from `ArticleAIText`)
   via the client. Collect processed `content` pieces in order; take `title` from the first
   chunk's result.
   - improveWriting / translate are structure-preserving → joined chunk contents are the result.
7. **Reduce (only if `summarize`):** concatenate the mapped contents, then run **one final
   summarize pass** over the concatenation (re-chunk if it still overflows; summaries are short,
   so this is normally a single call) to yield the single summary.
8. **Failure:** any generation error or empty/unusable result for an article → **drop** it.
9. Honor `Task.isCancelled` between articles (background-run parity).

`requestDelay` between articles is not needed (no rate limits) and is omitted for this path.

### Factory

`AggregationService` builds the processor from the resolved `AIConfig`:

```swift
let processor: AIProcessing = config.provider == .appleIntelligence
    ? AppleIntelligenceProcessor(client: AppleIntelligenceClient())
    : AIProcessor(config: config, requestDelay: requestDelay)
```

### Settings UI

- Provider picker gains "Apple Intelligence".
- When selected: hide API key / custom URL / model picker; show a **status row** driven by
  `AppleIntelligenceClient.availability`:
  - `.available` → "Available"
  - `.deviceNotEligible` → "Not available on this device"
  - `.notEnabled` → "Turn on Apple Intelligence in Settings"
  - `.modelNotReady` → "Model downloading…"
- Temperature / max-tokens tuning still apply; key-derived tuning (retries/timeouts/delays)
  is irrelevant to this path and simply unused.

### `AIConfig` gate change

The processor gate `!config.apiKey.isEmpty` becomes
`(config.provider == .appleIntelligence || !config.apiKey.isEmpty)`. No other `AIConfig`
fields change; Apple path ignores `apiKey`, `model`, `openaiAPIURL`, and the retry/timeout set.

## Localization

New `Localizable.xcstrings` entries, each `en` + `de`, `state: translated`, Apple German style:

| Key (English) | German |
|---|---|
| Apple Intelligence | Apple Intelligence |
| Available | Verfügbar |
| Not available on this device | Auf diesem Gerät nicht verfügbar |
| Turn on Apple Intelligence in Settings | Apple Intelligence in den Einstellungen aktivieren |
| Model downloading… | Modell wird geladen … |

## Testing

- **`ArticleAIText`**: instruction strings match server parity; `stripChrome` removes chrome;
  `cap` truncates at the boundary.
- **Chunker (pure)**: under-budget content → one chunk; multi-block content → multiple chunks
  respecting the token budget on block boundaries; a single oversized block → hard-split.
- **`AppleIntelligenceProcessor`** with injected availability + generator:
  - unavailable → passthrough (input returned unchanged, generator never called);
  - per-article generation error → article dropped;
  - improve/translate map → ordered concatenation, title from first chunk;
  - summarize → reduce pass invoked over concatenated content;
  - `Task.isCancelled` stops further articles.

Foundation Models cannot run on the simulator/CI, so all tests use injected fakes; no test
touches `SystemLanguageModel` directly.

## Out of scope

- Private Cloud Compute / server Foundation Models (WWDC 2026; not shipping).
- Routing existing external providers through the unified `LanguageModel` protocol.
- Image input, tool calling, streaming.

## Risks / notes

- **Quality of long-article summaries** via map-reduce is inherently lossier than a
  single-pass large-context call; acceptable for the on-device tier.
- **Translation** of non-English languages depends on the 3B model's coverage; consistent UI,
  variable quality — documented expectation.
- `tokenCount(for:)`/`contextSize` exist on iOS 26.4+; the client degrades to a char-based
  heuristic when absent so it builds and runs on 26.0.
