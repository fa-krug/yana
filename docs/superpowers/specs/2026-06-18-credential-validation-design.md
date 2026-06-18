# Credential Validation in Settings — Design

**Date:** 2026-06-18

## Problem

When configuring Reddit, YouTube, and the AI providers (OpenAI, Anthropic, Gemini)
in Settings, the user enters API keys / client secrets with no way to know whether
the values are correct. Validation only happens implicitly at aggregation time, where
a bad key surfaces as a generic feed-update failure far from where it was entered.

We want an explicit, in-Settings way to confirm that the entered credentials are
accepted by the provider.

## Goals

- An explicit **"Test" button** per credential section (Reddit, YouTube, and each AI
  provider) that makes a **minimal auth/identity call** using the values currently
  entered and reports the result inline.
- Distinguish three failure kinds: **invalid credentials**, **network/transport
  failure**, and **unexpected response**.
- Reuse the existing injected-`fetch` testing pattern so the verify logic is
  unit-testable without live network.

## Non-Goals

- No "full sample fetch" against a real feed identifier — minimal auth check only.
- No automatic validation on field change or on leaving the screen — explicit button.
- No change to aggregation-time validation behavior beyond what the test path needs.

## Architecture

Test logic lives on the existing clients (`RedditClient`, `YouTubeClient`,
`AIClient`); there is no new orchestrator service. Each gains a focused verify method
that performs the minimal call and maps the outcome onto a shared error type.

### Shared error type

```swift
enum CredentialTestError: Error, Equatable {
    case invalidCredentials   // HTTP 401/403; Reddit auth failure; YouTube 400
    case network              // transport error / timeout
    case unexpectedResponse   // unparseable or otherwise unexpected
}
```

`CredentialTestError` conforms to `LocalizedError` with a localized `errorDescription`
per case.

### Per-client verify methods

- **`RedditClient.verifyCredentials() async throws`** — performs the OAuth token
  request (same endpoint as `authToken()`). On 2xx with a token → success. The verify
  path must surface the HTTP **status code** so 401/403 map to `.invalidCredentials`,
  a transport throw maps to `.network`, and a 2xx-without-token / unparseable body maps
  to `.unexpectedResponse`. This is the only real plumbing change: the existing
  `authToken()` throws a generic `AggregatorError.contentFetch` and its `fetch` closure
  returns `Data` only, so the verify path needs access to the status code (e.g. a
  dedicated fetch that returns `(Data, HTTPURLResponse)` for the token request, or an
  equivalent). The existing aggregation fetch is left unchanged.

- **`YouTubeClient.verifyKey() async throws`** — one cheap Data API call (e.g.
  `channels?part=id&id=UC...` or a tiny `search`), enough for Google to accept or reject
  the key. Google returns **400** for a malformed/invalid key and **403** for
  blocked/quota; both map to `.invalidCredentials`. If the 403 body indicates a quota
  condition specifically, the message may note that; otherwise generic invalid.
  Transport throw → `.network`; unparseable → `.unexpectedResponse`.

- **`AIClient.verify() async throws`** — a minimal `generate(prompt: "ping",
  jsonMode: false)` with `maxTokens` forced low. Maps `AIClientError.httpStatus(401)` /
  `httpStatus(403)` → `.invalidCredentials`, `.invalidResponseShape` →
  `.unexpectedResponse`, other `httpStatus` → `.unexpectedResponse`, transport throw →
  `.network`.

## UI

In `SettingsScreenView`, each credential section gets:

- A **"Test" button**, disabled when the relevant field(s) are empty:
  - Reddit: needs both Client ID **and** Client Secret.
  - YouTube: needs the API key.
  - Each AI provider: needs that provider's key.
- A per-credential `@State` status enum:

  ```swift
  enum TestStatus: Equatable {
      case idle
      case testing
      case valid
      case invalid(String)   // localized message from CredentialTestError
  }
  ```

- An **inline status row** directly under the section's fields:
  - `idle` → no row (or neutral).
  - `testing` → spinner + "Testing…".
  - `valid` → "✓ Credentials valid".
  - `invalid` → "✗ " + the classified message.

Behavior:

- On tap → set `testing`, build the appropriate client from the current field value(s)
  plus relevant settings (AI: provider key + model + `openaiAPIURL`), run the verify
  call off the main actor, then set `valid` or `invalid(message)`.
- Any edit to a credential field resets that section's status to `idle` (the prior
  result no longer applies).
- AI: each provider section tests **its own** key independently (not just the active
  provider).

### Apple Intelligence

Apple Intelligence has no key. Its "Test" reports **on-device model availability**
instead of a network call (it is currently a status display, so this is a natural fit).

## Testing

- **TDD** for the three verify methods and the `CredentialTestError` mapping, using the
  existing `FetchRecorder` / injected-`fetch` pattern. Cases: 200 success, 401, 403,
  400 (YouTube), 2xx-without-token (Reddit), and a transport error — each asserting the
  expected `CredentialTestError` (or success).
- The SwiftUI status wiring is not unit-tested, consistent with the rest of the views.

## Localization

New user-facing strings added to `Localizable.xcstrings` with `de` translations marked
`"state" : "translated"` (Apple localization style, infinitive for actions):

- "Test"
- "Testing…"
- "Credentials valid" (success row)
- `CredentialTestError` messages: invalid credentials, network failure, unexpected
  response.

## Risks / Notes

- The Reddit status-code plumbing is the main change to existing client code; keep it
  scoped to the verify path so aggregation behavior is unaffected.
- A "Test" call consumes a small amount of provider quota (especially YouTube/AI).
  Minimal calls keep this negligible, and the button is explicit/user-initiated.
