# AI Support Improvements — Design

**Date:** 2026-06-18

## Goal

Improve the app's AI post-processing in three ways:

1. **Summary placement** — render the AI summary as its own block *between* the article
   header and body, rather than having the summary replace the body content.
2. **More providers** — add Mistral, Qwen (Alibaba DashScope), and DeepSeek as selectable
   AI providers.
3. **Provider-dependent config** — show only the selected provider's detailed configuration
   in Settings, mirroring the `AggregatorOptionsForm` switch-on-type pattern, instead of the
   current always-open DisclosureGroups for every provider.

## Background (current state)

- `AIProvider` (`Yana/Models/AppSettings.swift`) enumerates `none, openai, anthropic, gemini,
  appleIntelligence`, each with a `models: [String]` list and `defaultModel`.
- `AIClient` (`Yana/Services/AIClient.swift`) builds provider-specific requests in
  `buildRequest(...)`: OpenAI uses `/chat/completions` (bearer auth, JSON mode via
  `response_format`), Anthropic and Gemini are bespoke. Each has its own response parser.
- `AIProcessor` (`Yana/Services/AIProcessor.swift`) gates on toggles + concrete provider +
  non-empty key, strips chrome, builds a prompt asking for JSON `{title, content}`, and writes
  `parsed["title"]`/`parsed["content"]` back onto the article. **There is no summary field** —
  summarization rewrites `content` in place.
- `AppleIntelligenceProcessor` mirrors AIProcessor for on-device processing.
- Article content lives in `Article.content` (SwiftData `@Model`) and `AggregatedArticle.content`
  (DTO). `ArticleRenderer.articleSubstitutions` maps `article.content` → the `[[body]]` macro of
  the shared `page.html`; the 8 bundled NNW `.nnwtheme` themes share that template.
- Settings UI (`Yana/Views/Config/SettingsScreenView.swift`) shows a provider `Picker` plus an
  always-visible `DisclosureGroup` per provider (key field, model picker, Test button).
  `CredentialTester.ai(provider:apiKey:model:openaiAPIURL:)` builds an `AIConfig` and calls
  `AIClient.verify()`.
- `KeychainService.APIKeyItem` has cases for openai/anthropic/gemini keys.

## 1. New providers (Mistral, Qwen, DeepSeek)

All three expose **OpenAI-compatible** `/chat/completions` endpoints with bearer auth and JSON
mode, so they reuse the existing OpenAI request-builder and parser. They are still distinct
providers to the user (own key, own model list, own Test button).

### `AIProvider` enum changes (`AppSettings.swift`)

- Add cases `mistral`, `qwen`, `deepseek`.
- `displayName`: "Mistral", "Qwen", "DeepSeek".
- `models`:
  - `mistral`: `["mistral-small-latest", "mistral-large-latest", "mistral-medium-latest"]`
  - `qwen`: `["qwen-plus", "qwen-turbo", "qwen-max"]`
  - `deepseek`: `["deepseek-chat", "deepseek-reasoner"]`
  - (Model IDs reflect current offerings as of this spec; update as providers ship new ones,
    same maintenance note as the existing list.)
- New computed property `var baseURL: String` returning the chat-completions base for each
  OpenAI-compatible provider:
  - `openai`: the existing user-overridable `openaiAPIURL` value (resolved by the caller, not
    the enum — see below), defaulting to `https://api.openai.com/v1`.
  - `mistral`: `https://api.mistral.ai/v1`
  - `qwen`: `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`
  - `deepseek`: `https://api.deepseek.com/v1`
  - others: empty (not used).

  Implementation note: OpenAI's base URL remains user-configurable through `AppSettings.openaiAPIURL`.
  The new three use fixed bases. To keep one code path, `AIConfig` carries the resolved base URL
  (see below) rather than `AIClient` reading the enum directly.

### `AIConfig` change (`AIClient.swift`)

- Rename/generalize the existing `openaiAPIURL` field to a resolved `apiBaseURL: String` used by
  the OpenAI-compatible path. `makeAIConfig` sets it to `settings.openaiAPIURL` for `.openai` and
  to `provider.baseURL` for the new three. (Keep accepting the existing field name if simpler;
  the key requirement is the OpenAI request-builder reads a single base-URL string.)

### `AIClient.buildRequest` change

```swift
switch config.provider {
case .openai, .mistral, .qwen, .deepseek:
    return (try openaiCompatibleRequest(prompt: prompt, jsonMode: jsonMode), Self.parseOpenAI)
case .anthropic: return (try anthropicRequest(prompt: prompt), Self.parseAnthropic)
case .gemini:    return (try geminiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseGemini)
case .none, .appleIntelligence: throw AIClientError.unsupportedProvider
}
```

The OpenAI request-builder uses `config.apiBaseURL` for the endpoint host.

### `KeychainService.APIKeyItem` (`KeychainService.swift`)

Add cases: `mistralAPIKey = "mistral_api_key"`, `qwenAPIKey = "qwen_api_key"`,
`deepseekAPIKey = "deepseek_api_key"`.

### `AppSettings` model storage

Add `mistralModel`, `qwenModel`, `deepseekModel` String properties (UserDefaults-backed, same
pattern as `openaiModel`), defaulting to each provider's `defaultModel`.

### `AggregationService.makeAIConfig`

Extend the `switch provider` to handle the three new cases: set `model` from the corresponding
`AppSettings.*Model`, `keyItem` to the corresponding Keychain item, and `apiBaseURL` to
`provider.baseURL`.

## 2. Provider-dependent Settings UI

Mirror `AggregatorOptionsForm`'s switch-on-type approach.

- Keep the provider `Picker` over `AIProvider.allCases`.
- Replace the three always-open `DisclosureGroup`s with a single `@ViewBuilder` that switches on
  `settings.activeAIProvider` and renders only the selected provider's controls:
  - `.openai`: key `SecureField`, API URL `TextField`, model `Picker`, Test button.
  - `.anthropic` / `.gemini` / `.mistral` / `.qwen` / `.deepseek`: key `SecureField`, model
    `Picker`, Test button. (No API URL field — fixed base.)
  - `.appleIntelligence`: availability status + Test button (unchanged).
  - `.none`: nothing.
- Each provider's key continues to load on appear (`loadSecrets`) and save on change to Keychain.
  Keys for non-selected providers stay in Keychain; they're simply not shown. Per-provider
  `TestStatus` state remains.
- `CredentialTester.ai` receives the provider's resolved base URL (pass `provider.baseURL`, or
  `settings.openaiAPIURL` for OpenAI) so Test works for the new providers.

## 3. Summary between header and body

Summary becomes **additive**: when "Summarize" is on, the AI returns a separate summary in
addition to the (optionally improved/translated) full body. The body is preserved.

### Data model

- `AggregatedArticle` (DTO): add `var summary: String` (default `""`).
- `Article` (`@Model`): add `var summary: String = ""` (defaulted for SwiftData lightweight
  migration safety).
- The upsert in `AggregationService` copies `summary` from DTO → model alongside `content`.

### Prompt (`AIProcessor.buildPrompt`, shared `ArticleAIText` instructions)

- The base instruction lists JSON keys `title` and `content` as today.
- When `ai.summarize` is on, instruct the model to **also** include a `summary` key — a short
  plain-text or simple-HTML synopsis — and clarify that `content` must remain the full article
  (so summarize no longer means "replace the body"). The improve/translate instructions continue
  to act on `content`.
- When summarize is off, the `summary` key is not requested and the field stays empty.

### Apply step

- `AIProcessor.process`: after parsing, set `updated.summary = parsed["summary"] as? String ?? ""`
  (only meaningful when summarize was requested). `title`/`content` unchanged in behavior.
- `AppleIntelligenceProcessor`: produce the summary into the `summary` field (its existing
  map-reduce summarization output goes to `summary` rather than overwriting `content`; when
  summarize is off, leave empty).

### Rendering (`ArticleRenderer`)

- Do **not** add a new theme macro (keeps all 8 `.nnwtheme` templates and `page.html` untouched).
- In `articleSubstitutions`, when `article.summary` is non-empty, prepend a styled block to the
  `[[body]]` string:
  ```html
  <div class="yana-summary"><div class="yana-summary-label">Summary</div>…summary…</div>
  ```
  followed by `article.content`.
- The label is localized ("Summary" / "Zusammenfassung").
- Add `.yana-summary` styling (callout/quote treatment) to the shared article CSS under
  `Yana/Resources/ArticleRendering/` so it renders consistently across themes and adapts to
  light/dark via existing CSS variables.

## Testing

- **Unit (`YanaTests`, Swift Testing):**
  - `AIProvider`: new cases appear in `allCases`, correct `models`, `defaultModel`, and `baseURL`.
  - `makeAIConfig`: each new provider resolves the right model, Keychain item, and base URL.
  - `AIClient.buildRequest` / OpenAI-compatible builder: new providers produce a request hitting
    their base URL with bearer auth and JSON mode.
  - `AIProcessor.buildPrompt`: includes a `summary` instruction when summarize is on, omits it
    when off; `content` is described as the full article.
  - `AIProcessor.process`: populates `summary` from parsed JSON; leaves `content` intact when
    only summarize is on; drops article on invalid JSON (unchanged).
  - `ArticleRenderer`: summary block is prepended when summary non-empty; absent when empty;
    body unaffected.
- **Translations:** add "Summary" → "Zusammenfassung" and any new UI strings to
  `Localizable.xcstrings`, marked `translated` for `de`.

## Out of scope / YAGNI

- No bespoke request/response handling for the new providers (OpenAI-compatible only).
- No new theme macros; CSS-only summary styling.
- No retroactive summarization of already-stored articles (summary is populated at import time,
  consistent with the existing per-article processing model).
- No per-feed override of provider/model (stays global, as today).

## Migration notes

- Adding non-optional `summary: String = ""` to the `Article` `@Model` is a SwiftData lightweight
  migration (defaulted property). No manual migration required.
- New UserDefaults keys default cleanly; no existing-data impact.
