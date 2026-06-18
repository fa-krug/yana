# Credential Validation in Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit "Test" buttons in Settings that verify the entered Reddit, YouTube, and AI-provider credentials with a minimal auth/identity call and report the result inline.

**Architecture:** Each existing client (`RedditClient`, `YouTubeClient`, `AIClient`) gains a `verify*` method that performs its cheapest authenticated call and maps the outcome onto a shared `CredentialTestError` (`invalidCredentials` / `network` / `unexpectedResponse`). A thin `CredentialTester` facade builds a client from the values currently in the Settings fields and calls the verify method. `SettingsScreenView` holds a per-section `TestStatus` and renders an inline status row.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform: iOS 26.0+. Swift 6 strict concurrency — keep `Sendable`/`@MainActor` annotations consistent with surrounding code.
- New `.swift` files require `xcodegen generate` before they compile (the `.xcodeproj` is generated from `project.yml` folder globs). Run it after creating any new file and before building.
- **Localization is mandatory.** Every new user-facing string MUST be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state" : "translated"`. German uses Apple style (infinitive for actions, no "Du"/"Sie"). Source language is `en`; entries carry only a `de` localization block (the key itself is the English value), matching the existing `"Enabled"` entry.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`. Narrow to a suite with `-only-testing:YanaTests/<SuiteFileNameWithoutExtension>` where useful.
- Tests use the existing injected-`fetch` pattern. `RedditClient`/`YouTubeClient` use `typealias Fetch = @Sendable (URLRequest) async throws -> Data`; `AIClient` uses `@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`. With the **default** fetch, `HTTPClient.fetchJSON` maps 4xx → `AggregatorError.articleSkip(statusCode:)` and 5xx → `AggregatorError.contentFetch`. Tests simulate these by having the injected closure `throw` the corresponding error.

---

### Task 1: `CredentialTestError` type + localization

**Files:**
- Create: `Yana/Services/CredentialTester.swift`
- Create: `YanaTests/CredentialTesterTests.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces:
  - `enum CredentialTestError: Error, Equatable { case invalidCredentials, network, unexpectedResponse }`
  - `var localizedMessage: String` on `CredentialTestError` (the string shown in the inline error row).

- [ ] **Step 1: Write the failing test**

Create `YanaTests/CredentialTesterTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("CredentialTestError")
struct CredentialTesterTests {
    @Test func eachCaseHasANonEmptyLocalizedMessage() {
        for error in [CredentialTestError.invalidCredentials, .network, .unexpectedResponse] {
            #expect(!error.localizedMessage.isEmpty)
        }
    }

    @Test func messagesAreDistinct() {
        let messages = Set([
            CredentialTestError.invalidCredentials.localizedMessage,
            CredentialTestError.network.localizedMessage,
            CredentialTestError.unexpectedResponse.localizedMessage,
        ])
        #expect(messages.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/CredentialTesterTests test`
Expected: FAIL — `CredentialTestError` / `CredentialTester.swift` does not exist (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Yana/Services/CredentialTester.swift`:

```swift
import Foundation

/// The three outcomes a credential test can fail with. Mapped from each client's
/// domain errors so the Settings UI can show a specific, localized message.
enum CredentialTestError: Error, Equatable {
    case invalidCredentials   // provider rejected the key/secret (HTTP 401/403/400, or no token)
    case network              // transport failure, timeout, or server-side (5xx) error
    case unexpectedResponse   // 2xx-but-unparseable, or any other unexpected condition

    var localizedMessage: String {
        switch self {
        case .invalidCredentials:
            String(localized: "Invalid credentials. Check the values and try again.")
        case .network:
            String(localized: "Network error. Check your connection and try again.")
        case .unexpectedResponse:
            String(localized: "Unexpected response from the server.")
        }
    }
}
```

- [ ] **Step 4: Add German translations**

Run this script (idempotent — adds keys only if missing):

```bash
python3 - <<'PY'
import json
p = "Yana/Resources/Localizable.xcstrings"
d = json.load(open(p))
adds = {
    "Invalid credentials. Check the values and try again.": "Ungültige Zugangsdaten. Werte prüfen und erneut versuchen.",
    "Network error. Check your connection and try again.": "Netzwerkfehler. Verbindung prüfen und erneut versuchen.",
    "Unexpected response from the server.": "Unerwartete Antwort vom Server.",
}
for k, de in adds.items():
    d["strings"].setdefault(k, {})["localizations"] = {
        "de": {"stringUnit": {"state": "translated", "value": de}}
    }
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
print("added", len(adds))
PY
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/CredentialTesterTests test`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/CredentialTester.swift YanaTests/CredentialTesterTests.swift Yana/Resources/Localizable.xcstrings Yana.xcodeproj
git commit -m "feat(settings): add CredentialTestError type for credential validation"
```

---

### Task 2: `RedditClient.verifyCredentials()`

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditClient.swift` (add `authFailedMessage` constant + `verifyCredentials()`)
- Modify: `YanaTests/RedditClientTests.swift` (add tests)

**Interfaces:**
- Consumes: `CredentialTestError` (Task 1); existing `authToken()`.
- Produces: `func verifyCredentials() async -> CredentialTestError?` (nil = valid).

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/RedditClientTests.swift` inside the `RedditClientTests` suite:

```swift
@Test func verifySucceedsWhenTokenReturned() async {
    let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { _ in
        Data(#"{"access_token":"TKN","expires_in":3600}"#.utf8)
    }
    let result = await client.verifyCredentials()
    #expect(result == nil)
}

@Test func verifyReportsInvalidCredentialsOn401() async {
    let client = RedditClient(clientID: "bad", clientSecret: "bad", userAgent: "Yana/1.0") { _ in
        throw AggregatorError.articleSkip(statusCode: 401)
    }
    let result = await client.verifyCredentials()
    #expect(result == .invalidCredentials)
}

@Test func verifyReportsInvalidCredentialsWhenNoToken() async {
    let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { _ in
        Data(#"{"error":"invalid_grant"}"#.utf8)
    }
    let result = await client.verifyCredentials()
    #expect(result == .invalidCredentials)
}

@Test func verifyReportsNetworkOnServerError() async {
    let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { _ in
        throw AggregatorError.contentFetch("HTTP 503")
    }
    let result = await client.verifyCredentials()
    #expect(result == .network)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/RedditClient test`
Expected: FAIL — `verifyCredentials` does not exist (compile error).

- [ ] **Step 3: Add the auth-failed constant and use it**

In `Yana/Aggregators/Concrete/RedditClient.swift`, add a constant near the top of the class (e.g. just after `static func isExpired`):

```swift
    /// Message used when Reddit returns 2xx but no usable token (rare; treated as bad creds).
    static let authFailedMessage = "Reddit auth failed"
```

Then change the throw in `authToken()` to reuse it:

```swift
        guard let token = decoded?.accessToken, !token.isEmpty else {
            throw AggregatorError.contentFetch(Self.authFailedMessage)
        }
```

- [ ] **Step 4: Implement `verifyCredentials()`**

Add to the class (e.g. after `authToken()`):

```swift
    /// Minimal credential check: request an app-only OAuth token and classify the outcome.
    /// Returns nil when the token was issued (credentials valid).
    func verifyCredentials() async -> CredentialTestError? {
        do {
            _ = try await authToken()
            return nil
        } catch AggregatorError.articleSkip {
            return .invalidCredentials                       // 4xx: key/secret rejected
        } catch AggregatorError.contentFetch(Self.authFailedMessage) {
            return .invalidCredentials                       // 2xx but no token: grant rejected
        } catch is AggregatorError {
            return .network                                  // 5xx / size cap
        } catch {
            return .network                                  // transport (URLError) etc.
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/RedditClient test`
Expected: PASS (existing tests + 4 new).

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditClient.swift YanaTests/RedditClientTests.swift
git commit -m "feat(settings): add RedditClient.verifyCredentials for credential testing"
```

---

### Task 3: `YouTubeClient.verifyKey()`

**Files:**
- Modify: `Yana/Aggregators/Concrete/YouTubeClient.swift` (add `verifyKey()`)
- Modify: `YanaTests/YouTubeClientTests.swift` (add tests)

**Interfaces:**
- Consumes: `CredentialTestError` (Task 1); existing private `get(_:_:)`.
- Produces: `func verifyKey() async -> CredentialTestError?` (nil = valid).

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/YouTubeClientTests.swift` inside the `YouTubeClientTests` suite:

```swift
@Test func verifyKeySucceedsOn2xx() async {
    let client = YouTubeClient(apiKey: "K") { _ in Data(#"{"items":[]}"#.utf8) }
    let result = await client.verifyKey()
    #expect(result == nil)
}

@Test func verifyKeyReportsInvalidCredentialsOn400() async {
    let client = YouTubeClient(apiKey: "bad") { _ in
        throw AggregatorError.articleSkip(statusCode: 400)
    }
    let result = await client.verifyKey()
    #expect(result == .invalidCredentials)
}

@Test func verifyKeyReportsInvalidCredentialsOn403() async {
    let client = YouTubeClient(apiKey: "blocked") { _ in
        throw AggregatorError.articleSkip(statusCode: 403)
    }
    let result = await client.verifyKey()
    #expect(result == .invalidCredentials)
}

@Test func verifyKeyReportsNetworkOnServerError() async {
    let client = YouTubeClient(apiKey: "K") { _ in
        throw AggregatorError.contentFetch("HTTP 500")
    }
    let result = await client.verifyKey()
    #expect(result == .network)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/YouTubeClient test`
Expected: FAIL — `verifyKey` does not exist (compile error).

- [ ] **Step 3: Implement `verifyKey()`**

In `Yana/Aggregators/Concrete/YouTubeClient.swift`, add to the class (e.g. just before the `// MARK: - Request + URL helpers` section):

```swift
    /// Minimal key check: a cheap `channels` lookup against a known public channel id.
    /// A valid key returns 2xx (items may be empty); an invalid key returns 400/403.
    /// Returns nil when the key is accepted.
    func verifyKey() async -> CredentialTestError? {
        do {
            _ = try await get("channels", ["part": "id", "id": "UCBR8-60-B28hp2BmDPdntcQ"])
            return nil
        } catch AggregatorError.articleSkip {
            return .invalidCredentials                       // 400 bad key / 403 forbidden / quota
        } catch is AggregatorError {
            return .network                                  // 5xx / size cap
        } catch {
            return .network                                  // transport (URLError) etc.
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/YouTubeClient test`
Expected: PASS (existing tests + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/YouTubeClient.swift YanaTests/YouTubeClientTests.swift
git commit -m "feat(settings): add YouTubeClient.verifyKey for credential testing"
```

---

### Task 4: `AIClient.verify()`

**Files:**
- Modify: `Yana/Services/AIClient.swift` (add `verify()`)
- Modify: `YanaTests/AIClientTests.swift` (add tests)

**Interfaces:**
- Consumes: `CredentialTestError` (Task 1); existing `generate(prompt:jsonMode:)`, `AIClientError`.
- Produces: `func verify() async -> CredentialTestError?` (nil = valid).

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/AIClientTests.swift` inside the `AIClientTests` suite (the `config(...)` helper and `FetchRecorder` already exist):

```swift
@Test func verifySucceedsOn2xx() async {
    let body = #"{"choices":[{"message":{"content":"pong"}}]}"#
    let rec = FetchRecorder([(Data(body.utf8), 200)])
    let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)
    let result = await client.verify()
    #expect(result == nil)
}

@Test func verifyReportsInvalidCredentialsOn401() async {
    let rec = FetchRecorder([(Data("{}".utf8), 401)])
    let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)
    let result = await client.verify()
    #expect(result == .invalidCredentials)
}

@Test func verifyReportsInvalidCredentialsOn403() async {
    let rec = FetchRecorder([(Data("{}".utf8), 403)])
    let client = AIClient(config: config(provider: .anthropic), fetch: rec.fetch)
    let result = await client.verify()
    #expect(result == .invalidCredentials)
}

@Test func verifyReportsUnexpectedOnUnparseableBody() async {
    let rec = FetchRecorder([(Data("not json".utf8), 200)])
    let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)
    let result = await client.verify()
    #expect(result == .unexpectedResponse)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AIClient test`
Expected: FAIL — `verify` does not exist (compile error).

- [ ] **Step 3: Implement `verify()`**

In `Yana/Services/AIClient.swift`, add to the `AIClient` struct (e.g. just after `generate(prompt:jsonMode:)`):

```swift
    /// Minimal credential check: a tiny non-JSON generation. Returns nil when the provider
    /// accepts the key and returns a parseable response. Callers should build the `AIConfig`
    /// with a small `maxTokens` so the probe is cheap.
    func verify() async -> CredentialTestError? {
        do {
            _ = try await generate(prompt: "ping", jsonMode: false)
            return nil
        } catch AIClientError.httpStatus(let code) {
            return (code == 401 || code == 403 || code == 400) ? .invalidCredentials : .unexpectedResponse
        } catch AIClientError.invalidResponseShape, AIClientError.unsupportedProvider {
            return .unexpectedResponse
        } catch is URLError {
            return .network
        } catch {
            return .network
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AIClient test`
Expected: PASS (existing tests + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AIClient.swift YanaTests/AIClientTests.swift
git commit -m "feat(settings): add AIClient.verify for credential testing"
```

---

### Task 5: `CredentialTester` facade + Settings UI wiring

**Files:**
- Modify: `Yana/Services/CredentialTester.swift` (add the facade)
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (Test buttons + status rows)
- Modify: `Yana/Resources/Localizable.xcstrings` (UI strings)

**Interfaces:**
- Consumes: `RedditClient.verifyCredentials()`, `YouTubeClient.verifyKey()`, `AIClient.verify()`, `AIConfig`, `AIProvider`, `AppleIntelligenceClient`.
- Produces (facade, all return `CredentialTestError?`, nil = valid):
  - `CredentialTester.reddit(clientID:clientSecret:userAgent:) async`
  - `CredentialTester.youtube(apiKey:) async`
  - `CredentialTester.ai(provider:apiKey:model:openaiAPIURL:) async`

This task has no unit test (the facade composes already-tested verify methods with the live-network default fetch; the UI is SwiftUI). It is verified by a full build + test run.

- [ ] **Step 1: Add the `CredentialTester` facade**

Append to `Yana/Services/CredentialTester.swift`:

```swift
/// Builds a client from raw field values (live-network default fetch) and runs its verify
/// method. Pure composition over the per-client `verify*` methods, which carry the logic.
enum CredentialTester {
    static func reddit(clientID: String, clientSecret: String, userAgent: String) async -> CredentialTestError? {
        await RedditClient(clientID: clientID, clientSecret: clientSecret, userAgent: userAgent)
            .verifyCredentials()
    }

    static func youtube(apiKey: String) async -> CredentialTestError? {
        await YouTubeClient(apiKey: apiKey).verifyKey()
    }

    static func ai(provider: AIProvider, apiKey: String, model: String, openaiAPIURL: String) async -> CredentialTestError? {
        let config = AIConfig(
            provider: provider,
            model: model,
            apiKey: apiKey,
            openaiAPIURL: openaiAPIURL,
            temperature: 0.0,
            maxTokens: 16,       // tiny probe — keep the test cheap
            requestTimeout: 30,
            maxRetries: 0,
            retryDelay: 0,
            maxRetryTime: 10
        )
        return await AIClient(config: config).verify()
    }
}
```

- [ ] **Step 2: Add UI strings to localization**

```bash
python3 - <<'PY'
import json
p = "Yana/Resources/Localizable.xcstrings"
d = json.load(open(p))
adds = {
    "Test": "Testen",
    "Credentials valid": "Zugangsdaten gültig",
}
for k, de in adds.items():
    d["strings"].setdefault(k, {})["localizations"] = {
        "de": {"stringUnit": {"state": "translated", "value": de}}
    }
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
print("added", len(adds))
PY
```

- [ ] **Step 3: Add the `TestStatus` enum, state, and helpers to the view**

In `Yana/Views/Config/SettingsScreenView.swift`, add the enum just above `struct SettingsScreenView`:

```swift
/// Per-section credential-test state shown in Settings.
enum TestStatus: Equatable {
    case idle
    case testing
    case valid
    case invalid(String)   // localized message
}
```

Add these `@State` properties after the existing secret properties (after `geminiKey`):

```swift
    @State private var redditStatus: TestStatus = .idle
    @State private var youtubeStatus: TestStatus = .idle
    @State private var openaiStatus: TestStatus = .idle
    @State private var anthropicStatus: TestStatus = .idle
    @State private var geminiStatus: TestStatus = .idle
    @State private var appleStatus: TestStatus = .idle
```

Add these helper methods inside the struct (e.g. just before `loadSecrets()`):

```swift
    /// A "Test" button plus an inline status row, reused by every credential section.
    @ViewBuilder
    private func testControls(status: TestStatus, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("Test")
                if status == .testing {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(disabled || status == .testing)

        switch status {
        case .idle, .testing:
            EmptyView()
        case .valid:
            Label("Credentials valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    /// Run an async credential test, threading its status through `setter`.
    private func runTest(_ setter: @escaping (TestStatus) -> Void,
                         _ op: @escaping () async -> CredentialTestError?) {
        setter(.testing)
        Task {
            let error = await op()
            setter(error.map { .invalid($0.localizedMessage) } ?? .valid)
        }
    }
```

- [ ] **Step 4: Wire the Reddit section**

Replace `redditSection` with:

```swift
    private var redditSection: some View {
        Section("Reddit") {
            Toggle(isOn: $settings.redditEnabled) {
                Label("Enabled", systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.tintedIcon(.orange))
            }
            SecureField("Client ID", text: $redditClientID)
                .onChange(of: redditClientID) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientID); redditStatus = .idle
                }
            SecureField("Client Secret", text: $redditClientSecret)
                .onChange(of: redditClientSecret) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientSecret); redditStatus = .idle
                }
            TextField("User Agent", text: $settings.redditUserAgent)
                .autocorrectionDisabled()
            testControls(status: redditStatus,
                         disabled: redditClientID.isEmpty || redditClientSecret.isEmpty) {
                runTest({ redditStatus = $0 }) {
                    await CredentialTester.reddit(clientID: redditClientID,
                                                  clientSecret: redditClientSecret,
                                                  userAgent: settings.redditUserAgent)
                }
            }
        }
    }
```

- [ ] **Step 5: Wire the YouTube section**

Replace `youtubeSection` with:

```swift
    private var youtubeSection: some View {
        Section("YouTube") {
            Toggle(isOn: $settings.youtubeEnabled) {
                Label("Enabled", systemImage: "play.rectangle.fill")
                    .labelStyle(.tintedIcon(.red))
            }
            SecureField("API Key", text: $youtubeKey)
                .onChange(of: youtubeKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .youtubeAPIKey); youtubeStatus = .idle
                }
            testControls(status: youtubeStatus, disabled: youtubeKey.isEmpty) {
                runTest({ youtubeStatus = $0 }) {
                    await CredentialTester.youtube(apiKey: youtubeKey)
                }
            }
        }
    }
```

- [ ] **Step 6: Wire the AI provider sections (incl. Apple Intelligence)**

Replace the three `DisclosureGroup`s and the Apple Intelligence block in `aiProviderSection` with:

```swift
            DisclosureGroup("OpenAI") {
                SecureField("API Key", text: $openaiKey)
                    .onChange(of: openaiKey) { _, v in
                        KeychainService.saveAPIKey(v, for: .openaiAPIKey); openaiStatus = .idle
                    }
                TextField("API URL", text: $settings.openaiAPIURL).autocorrectionDisabled()
                Picker("Model", selection: $settings.openaiModel) {
                    ForEach(AIProvider.openai.models, id: \.self) { Text($0).tag($0) }
                }
                testControls(status: openaiStatus, disabled: openaiKey.isEmpty) {
                    runTest({ openaiStatus = $0 }) {
                        await CredentialTester.ai(provider: .openai, apiKey: openaiKey,
                                                  model: settings.openaiModel,
                                                  openaiAPIURL: settings.openaiAPIURL)
                    }
                }
            }
            DisclosureGroup("Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                    .onChange(of: anthropicKey) { _, v in
                        KeychainService.saveAPIKey(v, for: .anthropicAPIKey); anthropicStatus = .idle
                    }
                Picker("Model", selection: $settings.anthropicModel) {
                    ForEach(AIProvider.anthropic.models, id: \.self) { Text($0).tag($0) }
                }
                testControls(status: anthropicStatus, disabled: anthropicKey.isEmpty) {
                    runTest({ anthropicStatus = $0 }) {
                        await CredentialTester.ai(provider: .anthropic, apiKey: anthropicKey,
                                                  model: settings.anthropicModel,
                                                  openaiAPIURL: settings.openaiAPIURL)
                    }
                }
            }
            DisclosureGroup("Gemini") {
                SecureField("API Key", text: $geminiKey)
                    .onChange(of: geminiKey) { _, v in
                        KeychainService.saveAPIKey(v, for: .geminiAPIKey); geminiStatus = .idle
                    }
                Picker("Model", selection: $settings.geminiModel) {
                    ForEach(AIProvider.gemini.models, id: \.self) { Text($0).tag($0) }
                }
                testControls(status: geminiStatus, disabled: geminiKey.isEmpty) {
                    runTest({ geminiStatus = $0 }) {
                        await CredentialTester.ai(provider: .gemini, apiKey: geminiKey,
                                                  model: settings.geminiModel,
                                                  openaiAPIURL: settings.openaiAPIURL)
                    }
                }
            }
            if settings.activeAIProvider == .appleIntelligence {
                LabeledContent("Status", value: appleIntelligenceStatus)
                testControls(status: appleStatus, disabled: false) {
                    let available = AppleIntelligenceClient().availability == .available
                    appleStatus = available ? .valid : .invalid(appleIntelligenceStatus)
                }
            }
```

- [ ] **Step 7: Build and run the full test suite**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: BUILD SUCCEEDED and all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Yana/Services/CredentialTester.swift Yana/Views/Config/SettingsScreenView.swift Yana/Resources/Localizable.xcstrings Yana.xcodeproj
git commit -m "feat(settings): add Test buttons to validate Reddit, YouTube, and AI credentials"
```

---

## Self-Review Notes

- **Spec coverage:** Explicit per-section Test button (Task 5) ✓; minimal auth/identity calls (Tasks 2–4) ✓; three-way error classification with localized messages (Task 1, mapping in 2–4) ✓; inline status row that resets on edit (Task 5, `onChange` → `.idle`) ✓; per-provider AI test incl. Apple Intelligence availability (Task 5) ✓; injected-fetch unit tests (Tasks 2–4) ✓; German translations (Tasks 1 & 5) ✓.
- **Reddit status-code plumbing:** The spec flagged this as a risk. The implementation instead leverages the existing `HTTPClient.fetchJSON` mapping (4xx → `articleSkip`, 5xx → `contentFetch`), so no change to the aggregation fetch path is needed beyond extracting the `authFailedMessage` literal — simpler and lower-risk than the spec anticipated.
- **Type consistency:** `verifyCredentials()` / `verifyKey()` / `verify()` all return `CredentialTestError?`; `localizedMessage` is the single rendering point used by the view; `TestStatus.invalid(String)` carries that message.
