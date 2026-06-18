# AI Support Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Mistral/Qwen/DeepSeek as AI providers, make the Settings AI config depend on the selected provider, and render the AI summary as its own block between the article header and body (instead of replacing the body).

**Architecture:** Mistral, Qwen, and DeepSeek are OpenAI-compatible, so they reuse `AIClient`'s OpenAI request/parse path with a per-provider base URL. A new `summary` field flows through `AggregatedArticle` → `Article` and is rendered as a styled block prepended to the body. The Settings AI section switches on the active provider to show only its config, mirroring `AggregatorOptionsForm`.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform iOS 26.0+; Swift 6 strict concurrency — keep `@MainActor` / `Sendable` annotations consistent with surrounding code.
- All new user-facing strings MUST be added to `Yana/Resources/Localizable.xcstrings` with a German (`de`) translation marked `"state" : "translated"`. German uses Apple style (infinitive, no Du/Sie).
- Tests are Swift Testing (`@Test`, `#expect`), all `@MainActor`, under `YanaTests/`.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- After editing `project.yml` or adding files, run `xcodegen generate` before building. New `.swift` test files under `YanaTests/` are picked up by the existing source globs — no `project.yml` edit needed unless a new top-level group is introduced.
- Commit after each task with a `feat:`/`refactor:`/`docs:` message.

---

### Task 1: Add Mistral/Qwen/DeepSeek to `AIProvider`

**Files:**
- Modify: `Yana/Models/AppSettings.swift:3-35` (the `AIProvider` enum)
- Test: `YanaTests/AIProviderTests.swift` (create)

**Interfaces:**
- Produces: `AIProvider` gains cases `.mistral`, `.qwen`, `.deepseek`; each has `displayName`, `models`, `defaultModel`, and a new `var baseURL: String`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AIProviderTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct AIProviderTests {
    @Test func newProvidersAreSelectable() {
        let all = AIProvider.allCases
        #expect(all.contains(.mistral))
        #expect(all.contains(.qwen))
        #expect(all.contains(.deepseek))
    }

    @Test func newProvidersHaveModelsAndDefault() {
        for p in [AIProvider.mistral, .qwen, .deepseek] {
            #expect(!p.models.isEmpty)
            #expect(p.defaultModel == p.models.first)
        }
    }

    @Test func baseURLsAreProviderSpecific() {
        #expect(AIProvider.mistral.baseURL == "https://api.mistral.ai/v1")
        #expect(AIProvider.qwen.baseURL == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        #expect(AIProvider.deepseek.baseURL == "https://api.deepseek.com/v1")
        #expect(AIProvider.openai.baseURL == "https://api.openai.com/v1")
    }

    @Test func displayNames() {
        #expect(AIProvider.mistral.displayName == "Mistral")
        #expect(AIProvider.qwen.displayName == "Qwen")
        #expect(AIProvider.deepseek.displayName == "DeepSeek")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProviderTests`
Expected: FAIL — `.mistral`/`.qwen`/`.deepseek` / `baseURL` do not exist (compile error).

- [ ] **Step 3: Implement the enum changes**

In `Yana/Models/AppSettings.swift`, replace the `AIProvider` enum (lines 3-35) with:

```swift
enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case none
    case openai
    case anthropic
    case gemini
    case mistral
    case qwen
    case deepseek
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .mistral: "Mistral"
        case .qwen: "Qwen"
        case .deepseek: "DeepSeek"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    /// iOS-maintained current model lists (the server's choice lists are stale).
    /// Update these as providers ship new models.
    var models: [String] {
        switch self {
        case .none: []
        case .openai: ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini", "o3"]
        case .anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .mistral: ["mistral-small-latest", "mistral-large-latest", "mistral-medium-latest"]
        case .qwen: ["qwen-plus", "qwen-turbo", "qwen-max"]
        case .deepseek: ["deepseek-chat", "deepseek-reasoner"]
        case .appleIntelligence: []
        }
    }

    var defaultModel: String { models.first ?? "" }

    /// Default chat-completions base URL for the OpenAI-compatible providers. For `.openai`
    /// the user-overridable `AppSettings.openaiAPIURL` takes precedence (resolved by callers);
    /// the other three use these fixed bases. Empty for providers that don't use this path.
    var baseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .qwen: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .none, .anthropic, .gemini, .appleIntelligence: ""
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProviderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift YanaTests/AIProviderTests.swift
git commit -m "feat(ai): add Mistral, Qwen, DeepSeek to AIProvider"
```

---

### Task 2: Keychain items + per-provider model settings

**Files:**
- Modify: `Yana/Services/KeychainService.swift:57-64` (`APIKeyItem` enum)
- Modify: `Yana/Models/AppSettings.swift` (register defaults ~48-67; `Key` enum ~79-83; provider model properties ~161-172)
- Test: `YanaTests/AppSettingsAIProviderTests.swift` (create)

**Interfaces:**
- Produces: `KeychainService.APIKeyItem` gains `.mistralAPIKey`, `.qwenAPIKey`, `.deepseekAPIKey`. `AppSettings` gains `var mistralModel`, `var qwenModel`, `var deepseekModel: String`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AppSettingsAIProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
struct AppSettingsAIProviderTests {
    private func freshSettings() -> AppSettings {
        let suite = "test.aiproviders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AppSettings(defaults: defaults)
    }

    @Test func modelDefaultsMatchProviderDefaults() {
        let s = freshSettings()
        #expect(s.mistralModel == AIProvider.mistral.defaultModel)
        #expect(s.qwenModel == AIProvider.qwen.defaultModel)
        #expect(s.deepseekModel == AIProvider.deepseek.defaultModel)
    }

    @Test func modelsArePersisted() {
        let s = freshSettings()
        s.mistralModel = "mistral-large-latest"
        s.qwenModel = "qwen-max"
        s.deepseekModel = "deepseek-reasoner"
        #expect(s.mistralModel == "mistral-large-latest")
        #expect(s.qwenModel == "qwen-max")
        #expect(s.deepseekModel == "deepseek-reasoner")
    }

    @Test func keychainItemsHaveDistinctAccounts() {
        let accounts = Set([
            KeychainService.APIKeyItem.mistralAPIKey.rawValue,
            KeychainService.APIKeyItem.qwenAPIKey.rawValue,
            KeychainService.APIKeyItem.deepseekAPIKey.rawValue,
        ])
        #expect(accounts.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsAIProviderTests`
Expected: FAIL — members don't exist (compile error).

- [ ] **Step 3: Add the Keychain cases**

In `Yana/Services/KeychainService.swift`, extend the `APIKeyItem` enum (lines 57-64):

```swift
    enum APIKeyItem: String, Sendable {
        case redditClientID = "reddit_client_id"
        case redditClientSecret = "reddit_client_secret"
        case youtubeAPIKey = "youtube_api_key"
        case openaiAPIKey = "openai_api_key"
        case anthropicAPIKey = "anthropic_api_key"
        case geminiAPIKey = "gemini_api_key"
        case mistralAPIKey = "mistral_api_key"
        case qwenAPIKey = "qwen_api_key"
        case deepseekAPIKey = "deepseek_api_key"
    }
```

- [ ] **Step 4: Add the AppSettings model properties**

In `Yana/Models/AppSettings.swift`:

In the `defaults.register` dictionary (after `Key.geminiModel: "gemini-2.5-flash",` at line 55), add:

```swift
            Key.mistralModel: "mistral-small-latest",
            Key.qwenModel: "qwen-plus",
            Key.deepseekModel: "deepseek-chat",
```

In the `Key` enum (after `static let geminiModel = "settings.geminiModel"` at line 83), add:

```swift
        static let mistralModel = "settings.mistralModel"
        static let qwenModel = "settings.qwenModel"
        static let deepseekModel = "settings.deepseekModel"
```

After the `geminiModel` computed property (after line 172), add:

```swift
    var mistralModel: String {
        get { access(keyPath: \.mistralModel); return defaults.string(forKey: Key.mistralModel) ?? "mistral-small-latest" }
        set { withMutation(keyPath: \.mistralModel) { defaults.set(newValue, forKey: Key.mistralModel) } }
    }
    var qwenModel: String {
        get { access(keyPath: \.qwenModel); return defaults.string(forKey: Key.qwenModel) ?? "qwen-plus" }
        set { withMutation(keyPath: \.qwenModel) { defaults.set(newValue, forKey: Key.qwenModel) } }
    }
    var deepseekModel: String {
        get { access(keyPath: \.deepseekModel); return defaults.string(forKey: Key.deepseekModel) ?? "deepseek-chat" }
        set { withMutation(keyPath: \.deepseekModel) { defaults.set(newValue, forKey: Key.deepseekModel) } }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsAIProviderTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/KeychainService.swift Yana/Models/AppSettings.swift YanaTests/AppSettingsAIProviderTests.swift
git commit -m "feat(ai): add Keychain items and model settings for new providers"
```

---

### Task 3: Route new providers through the OpenAI-compatible path in `AIClient`

**Files:**
- Modify: `Yana/Services/AIClient.swift` (`AIConfig` field 11; `buildRequest` 79-89; `openaiRequest` 100-112; `geminiRequest` schema 143-150)
- Test: `YanaTests/AIClientCompatTests.swift` (create)

**Interfaces:**
- Consumes: `AIProvider.baseURL` (Task 1).
- Produces: `AIConfig.openaiAPIURL` is renamed to `apiBaseURL`. `AIClient` builds requests for `.openai/.mistral/.qwen/.deepseek` via one OpenAI-compatible builder using `config.apiBaseURL`. Gemini JSON schema gains an optional `summary` property.

Note: renaming `AIConfig.openaiAPIURL` → `apiBaseURL` requires updating its two other constructors — `AggregationService.makeAIConfig` (Task 4) and `CredentialTester.ai` (Task 5). Those tasks fix the call sites; this task's build will not fully compile until Task 4 and Task 5 land. To keep this task independently testable, **also update those two call sites in this task** (minimal: pass the same value to the renamed field), then Tasks 4–5 refine them. Concretely, in Step 3 below you also change `makeAIConfig` line 125 and `CredentialTester.ai` line 39 to use `apiBaseURL:`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AIClientCompatTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

struct AIClientCompatTests {
    private func config(_ provider: AIProvider, baseURL: String) -> AIConfig {
        AIConfig(provider: provider, model: "m", apiKey: "k", apiBaseURL: baseURL,
                 temperature: 0.3, maxTokens: 100, requestTimeout: 30,
                 maxRetries: 0, retryDelay: 0, maxRetryTime: 10)
    }

    /// Capture the outgoing request and return a canned OpenAI-shaped success body.
    private func captureClient(_ cfg: AIConfig, capture: @escaping @Sendable (URLRequest) -> Void) -> AIClient {
        AIClient(config: cfg) { request in
            capture(request)
            let body = #"{"choices":[{"message":{"content":"{\"title\":\"t\",\"content\":\"c\"}"}}]}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }
    }

    @Test func mistralHitsMistralBaseURLWithBearerAuth() async throws {
        let cfg = config(.mistral, baseURL: AIProvider.mistral.baseURL)
        nonisolated(unsafe) var captured: URLRequest?
        let client = captureClient(cfg) { captured = $0 }
        _ = try await client.generate(prompt: "p", jsonMode: true)
        #expect(captured?.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func deepseekAndQwenUseTheSameBuilder() async throws {
        for p in [AIProvider.deepseek, .qwen] {
            let cfg = config(p, baseURL: p.baseURL)
            nonisolated(unsafe) var captured: URLRequest?
            let client = captureClient(cfg) { captured = $0 }
            _ = try await client.generate(prompt: "p", jsonMode: true)
            #expect(captured?.url?.absoluteString == "\(p.baseURL)/chat/completions")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIClientCompatTests`
Expected: FAIL — `apiBaseURL` label doesn't exist; new providers hit `.unsupportedProvider`.

- [ ] **Step 3: Implement the AIClient changes (and fix the two call sites)**

In `Yana/Services/AIClient.swift`:

Rename the field (line 11) in `AIConfig`:

```swift
    var apiBaseURL: String
```

Update the doc comment on `AIConfig` (lines 4-6) to mention the OpenAI-compatible providers:

```swift
/// Immutable, `Sendable` snapshot of the AI configuration for one run. Built on the main
/// actor from `AppSettings` + `KeychainService`, then handed to off-main code. `provider`
/// is resolved to a concrete one; `.none` means AI is off and no `AIClient` is constructed.
/// `apiBaseURL` is the chat-completions base for the OpenAI-compatible providers
/// (`.openai/.mistral/.qwen/.deepseek`).
```

Replace `buildRequest` (lines 83-88 inside the `switch`):

```swift
        switch config.provider {
        case .openai, .mistral, .qwen, .deepseek:
            return (try openAICompatibleRequest(prompt: prompt, jsonMode: jsonMode), Self.parseOpenAI)
        case .anthropic: return (try anthropicRequest(prompt: prompt), Self.parseAnthropic)
        case .gemini: return (try geminiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseGemini)
        case .none, .appleIntelligence: throw AIClientError.unsupportedProvider
        }
```

Rename `openaiRequest` (line 100) to `openAICompatibleRequest` and use `config.apiBaseURL`:

```swift
    private func openAICompatibleRequest(prompt: String, jsonMode: Bool) throws -> URLRequest {
        guard let url = URL(string: "\(config.apiBaseURL)/chat/completions") else {
            throw AIClientError.invalidResponseShape
        }
        var body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        return try jsonRequest(url: url, headers: ["Authorization": "Bearer \(config.apiKey)"], body: body)
    }
```

In `geminiRequest`, add an optional `summary` property to the response schema (replace lines 143-150):

```swift
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"],
                    "content": ["type": "STRING"],
                    "summary": ["type": "STRING"],
                ],
                "required": ["title", "content"],
            ]
```

Now fix the two other `AIConfig` constructors so the project compiles:

- `Yana/Services/AggregationService.swift:125` — change `openaiAPIURL: settings.openaiAPIURL,` to `apiBaseURL: settings.openaiAPIURL,` (Task 4 refines this per-provider).
- `Yana/Services/CredentialTester.swift:39` — change `openaiAPIURL: openaiAPIURL,` to `apiBaseURL: openaiAPIURL,` (Task 5 refines this).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIClientCompatTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AIClient.swift Yana/Services/AggregationService.swift Yana/Services/CredentialTester.swift YanaTests/AIClientCompatTests.swift
git commit -m "feat(ai): route Mistral/Qwen/DeepSeek through OpenAI-compatible client path"
```

---

### Task 4: Resolve new providers in `makeAIConfig`

**Files:**
- Modify: `Yana/Services/AggregationService.swift:96-133` (`makeAIConfig`)
- Test: `YanaTests/MakeAIConfigTests.swift` (create)

**Interfaces:**
- Consumes: `AppSettings.mistralModel/qwenModel/deepseekModel` (Task 2), `KeychainService.APIKeyItem.mistralAPIKey/qwenAPIKey/deepseekAPIKey` (Task 2), `AIProvider.baseURL` (Task 1), `AIConfig.apiBaseURL` (Task 3).
- Produces: `makeAIConfig` returns correct `model`, `apiKey`, and `apiBaseURL` for the three new providers.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/MakeAIConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
struct MakeAIConfigTests {
    private func settings(provider: AIProvider) -> AppSettings {
        let defaults = UserDefaults(suiteName: "test.makeaiconfig.\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        s.activeAIProvider = provider
        return s
    }

    @Test func mistralResolvesModelKeyAndBaseURL() {
        let s = settings(provider: .mistral)
        s.mistralModel = "mistral-large-latest"
        let cfg = AggregationService.makeAIConfig(settings: s) { item in
            item == .mistralAPIKey ? "MK" : nil
        }
        #expect(cfg.provider == .mistral)
        #expect(cfg.model == "mistral-large-latest")
        #expect(cfg.apiKey == "MK")
        #expect(cfg.apiBaseURL == "https://api.mistral.ai/v1")
    }

    @Test func qwenAndDeepseekResolveBaseURLs() {
        let q = AggregationService.makeAIConfig(settings: settings(provider: .qwen)) { _ in "K" }
        #expect(q.apiBaseURL == AIProvider.qwen.baseURL)
        let d = AggregationService.makeAIConfig(settings: settings(provider: .deepseek)) { _ in "K" }
        #expect(d.apiBaseURL == AIProvider.deepseek.baseURL)
    }

    @Test func openaiStillUsesUserOverridableURL() {
        let s = settings(provider: .openai)
        s.openaiAPIURL = "https://proxy.example.com/v1"
        let cfg = AggregationService.makeAIConfig(settings: s) { _ in "K" }
        #expect(cfg.apiBaseURL == "https://proxy.example.com/v1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MakeAIConfigTests`
Expected: FAIL — new providers fall through to default-less switch (compile error: switch not exhaustive) or wrong `apiBaseURL`.

- [ ] **Step 3: Implement the makeAIConfig changes**

In `Yana/Services/AggregationService.swift`, replace the body of `makeAIConfig` (lines 100-132) with:

```swift
        let provider = settings.activeAIProvider
        let model: String
        let keyItem: KeychainService.APIKeyItem?
        switch provider {
        case .none:
            model = ""
            keyItem = nil
        case .openai:
            model = settings.openaiModel
            keyItem = .openaiAPIKey
        case .anthropic:
            model = settings.anthropicModel
            keyItem = .anthropicAPIKey
        case .gemini:
            model = settings.geminiModel
            keyItem = .geminiAPIKey
        case .mistral:
            model = settings.mistralModel
            keyItem = .mistralAPIKey
        case .qwen:
            model = settings.qwenModel
            keyItem = .qwenAPIKey
        case .deepseek:
            model = settings.deepseekModel
            keyItem = .deepseekAPIKey
        case .appleIntelligence:
            model = ""
            keyItem = nil
        }
        let key = keyItem.flatMap(loadKey) ?? ""
        // OpenAI honors the user-overridable URL; the other OpenAI-compatible providers use
        // their fixed base. Non-compatible providers (Anthropic/Gemini) ignore this field.
        let apiBaseURL = provider == .openai ? settings.openaiAPIURL : provider.baseURL
        return AIConfig(
            provider: provider,
            model: model,
            apiKey: key,
            apiBaseURL: apiBaseURL,
            temperature: settings.aiTemperature,
            maxTokens: settings.aiMaxTokens,
            requestTimeout: settings.aiRequestTimeout,
            maxRetries: settings.aiMaxRetries,
            retryDelay: settings.aiRetryDelay,
            maxRetryTime: 60
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MakeAIConfigTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/MakeAIConfigTests.swift
git commit -m "feat(ai): resolve Mistral/Qwen/DeepSeek config in makeAIConfig"
```

---

### Task 5: `CredentialTester.ai` resolves the provider base URL

**Files:**
- Modify: `Yana/Services/CredentialTester.swift:34-48`
- Test: `YanaTests/CredentialTesterAITests.swift` (create)

**Interfaces:**
- Consumes: `AIProvider.baseURL` (Task 1), `AIConfig.apiBaseURL` (Task 3).
- Produces: `CredentialTester.ai(provider:apiKey:model:openaiAPIURL:)` keeps its signature but resolves the OpenAI override vs. fixed base URL internally so the probe hits the right host.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/CredentialTesterAITests.swift`. This verifies the resolution helper that the tester uses (extracted so it's unit-testable without network):

```swift
import Testing
@testable import Yana

struct CredentialTesterAITests {
    @Test func openaiUsesOverrideURL() {
        #expect(CredentialTester.aiBaseURL(provider: .openai, openaiAPIURL: "https://x/v1") == "https://x/v1")
    }

    @Test func compatibleProvidersUseFixedBase() {
        #expect(CredentialTester.aiBaseURL(provider: .mistral, openaiAPIURL: "https://x/v1") == AIProvider.mistral.baseURL)
        #expect(CredentialTester.aiBaseURL(provider: .qwen, openaiAPIURL: "ignored") == AIProvider.qwen.baseURL)
        #expect(CredentialTester.aiBaseURL(provider: .deepseek, openaiAPIURL: "ignored") == AIProvider.deepseek.baseURL)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CredentialTesterAITests`
Expected: FAIL — `aiBaseURL` does not exist (compile error).

- [ ] **Step 3: Implement the resolution helper and use it**

In `Yana/Services/CredentialTester.swift`, replace the `ai(...)` method (lines 34-48) with:

```swift
    /// Resolve the chat-completions base URL for an AI probe: the user-overridable URL for
    /// OpenAI, the provider's fixed base for the other OpenAI-compatible providers, otherwise
    /// the provider base (unused by Anthropic/Gemini, which target hardcoded endpoints).
    static func aiBaseURL(provider: AIProvider, openaiAPIURL: String) -> String {
        provider == .openai ? openaiAPIURL : provider.baseURL
    }

    static func ai(provider: AIProvider, apiKey: String, model: String, openaiAPIURL: String) async -> CredentialTestError? {
        let config = AIConfig(
            provider: provider,
            model: model,
            apiKey: apiKey,
            apiBaseURL: aiBaseURL(provider: provider, openaiAPIURL: openaiAPIURL),
            temperature: 0.0,
            maxTokens: 16,       // tiny probe — keep the test cheap
            requestTimeout: 30,
            maxRetries: 0,
            retryDelay: 0,
            maxRetryTime: 10
        )
        return await AIClient(config: config).verify()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CredentialTesterAITests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/CredentialTester.swift YanaTests/CredentialTesterAITests.swift
git commit -m "feat(ai): resolve provider base URL in CredentialTester probe"
```

---

### Task 6: Add the `summary` field to the article model + upsert

**Files:**
- Modify: `Yana/Aggregators/AggregatedArticle.swift`
- Modify: `Yana/Models/Article.swift`
- Modify: `Yana/Aggregators/ArticleUpsert.swift`
- Modify: `Yana/Services/AggregationService.swift:227-231` (the `forceReload(article:)` seed)
- Test: `YanaTests/ArticleSummaryUpsertTests.swift` (create)

**Interfaces:**
- Produces: `AggregatedArticle.summary: String` (default `""`); `Article.summary: String = ""` with an `init` parameter `summary: String = ""`; `ArticleUpsert.apply` copies `summary` on both insert and update.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSummaryUpsertTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct ArticleSummaryUpsertTests {
    private func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Article.self, Tag.self, configurations: config)
        return ModelContext(container)
    }

    @Test func insertCopiesSummary() throws {
        let ctx = try context()
        let feed = Feed(name: "F", type: .feedContent)
        ctx.insert(feed)
        let agg = AggregatedArticle(title: "T", identifier: "id1", url: "https://e.com/1",
                                    rawContent: "", content: "<p>body</p>", date: .now,
                                    author: "", iconURL: nil, summary: "the summary")
        _ = ArticleUpsert.apply([agg], to: feed, starredTag: nil, context: ctx, now: .now)
        #expect(feed.articles.first?.summary == "the summary")
    }

    @Test func updateRefreshesSummary() throws {
        let ctx = try context()
        let feed = Feed(name: "F", type: .feedContent)
        ctx.insert(feed)
        let v1 = AggregatedArticle(title: "T", identifier: "id1", url: "u", rawContent: "",
                                   content: "c", date: .now, author: "", iconURL: nil, summary: "s1")
        _ = ArticleUpsert.apply([v1], to: feed, starredTag: nil, context: ctx, now: .now)
        let v2 = AggregatedArticle(title: "T", identifier: "id1", url: "u", rawContent: "",
                                   content: "c", date: .now, author: "", iconURL: nil, summary: "s2")
        _ = ArticleUpsert.apply([v2], to: feed, starredTag: nil, context: ctx, now: .now)
        #expect(feed.articles.count == 1)
        #expect(feed.articles.first?.summary == "s2")
    }
}
```

(If `Feed`'s initializer signature differs, match the existing one — check `Yana/Models/Feed.swift`. The summary assertions are the point.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryUpsertTests`
Expected: FAIL — `summary:` label doesn't exist on `AggregatedArticle` (compile error).

- [ ] **Step 3: Add `summary` to the DTO**

In `Yana/Aggregators/AggregatedArticle.swift`, add a field after `iconURL` (line 13):

```swift
    var iconURL: String?
    /// AI-generated summary, rendered as a block between the article header and body.
    /// Empty when summarization is off or unavailable.
    var summary: String = ""
```

- [ ] **Step 4: Add `summary` to the SwiftData model**

In `Yana/Models/Article.swift`:

Add the stored property after `iconURL` (line 14):

```swift
    var iconURL: String?
    /// AI-generated summary, shown above the body in the reader. Defaulted for lightweight
    /// SwiftData migration; empty when summarization is off.
    var summary: String = ""
```

Add the init parameter (after `iconURL: String? = nil` at line 30) and assignment:

```swift
        iconURL: String? = nil,
        summary: String = ""
    ) {
```

and inside the init body, after `self.iconURL = iconURL` (line 39):

```swift
        self.iconURL = iconURL
        self.summary = summary
```

- [ ] **Step 5: Copy `summary` in upsert**

In `Yana/Aggregators/ArticleUpsert.swift`:

In the update branch, after `existing.iconURL = item.iconURL`:

```swift
                existing.iconURL = item.iconURL
                existing.summary = item.summary
```

In the insert branch, add the argument to the `Article(...)` initializer (after `iconURL: item.iconURL`):

```swift
                    iconURL: item.iconURL,
                    summary: item.summary
```

- [ ] **Step 6: Carry `summary` through the `forceReload(article:)` seed**

In `Yana/Services/AggregationService.swift`, the seed `AggregatedArticle` (lines 227-231) — add `summary`:

```swift
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: article.rawContent, content: article.content, date: article.date,
            author: article.author, iconURL: article.iconURL, summary: article.summary
        )
```

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryUpsertTests`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Yana/Aggregators/AggregatedArticle.swift Yana/Models/Article.swift Yana/Aggregators/ArticleUpsert.swift Yana/Services/AggregationService.swift YanaTests/ArticleSummaryUpsertTests.swift
git commit -m "feat(ai): add additive summary field to article model and upsert"
```

---

### Task 7: Cloud `AIProcessor` — request summary additively, keep body intact

**Files:**
- Modify: `Yana/Services/AIProcessor.swift` (`process` 58-67; `buildPrompt` 74-109)
- Test: `YanaTests/AIProcessorSummaryTests.swift` (create)

**Interfaces:**
- Consumes: `AggregatedArticle.summary` (Task 6), `AIOptions` (`Yana/Models/AggregatorOptions.swift:4-9`).
- Produces: when `ai.summarize` is on, the prompt asks for a third JSON key `summary` and instructs the model to keep `content` as the full article; `process` writes `parsed["summary"]` into `updated.summary`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AIProcessorSummaryTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

struct AIProcessorSummaryTests {
    private func config() -> AIConfig {
        AIConfig(provider: .openai, model: "m", apiKey: "k", apiBaseURL: "https://api.openai.com/v1",
                 temperature: 0.3, maxTokens: 100, requestTimeout: 30,
                 maxRetries: 0, retryDelay: 0, maxRetryTime: 10)
    }

    private func article() -> AggregatedArticle {
        AggregatedArticle(title: "T", identifier: "id", url: "u", rawContent: "",
                          content: "<p>full body</p>", date: .now, author: "", iconURL: nil)
    }

    @Test func summarizePromptRequestsSummaryKeyAndPreservesContent() {
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let prompt = AIProcessor.buildPrompt(title: "T", cleanHTML: "<p>x</p>", ai: ai)
        #expect(prompt.contains("'summary'") || prompt.contains("summary"))
        #expect(prompt.lowercased().contains("full article") || prompt.lowercased().contains("do not replace"))
    }

    @Test func noSummaryKeyWhenSummarizeOff() {
        let ai = AIOptions(summarize: false, improveWriting: true, translate: false, translateLanguage: "English")
        let prompt = AIProcessor.buildPrompt(title: "T", cleanHTML: "<p>x</p>", ai: ai)
        #expect(!prompt.contains("'summary'"))
    }

    @Test func processPopulatesSummaryAndKeepsContent() async {
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let processor = AIProcessor(config: config(), requestDelay: 0) { _, _ in
            #"{"title":"T","content":"<p>full body</p>","summary":"short summary"}"#
        }
        let out = await processor.process([article()], ai: ai)
        #expect(out.count == 1)
        #expect(out.first?.summary == "short summary")
        #expect(out.first?.content == "<p>full body</p>")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorSummaryTests`
Expected: FAIL — prompt has no summary instruction; `summary` not populated.

- [ ] **Step 3: Update `buildPrompt`**

In `Yana/Services/AIProcessor.swift`, replace the base-instruction append (lines 77-82) so the key list is conditional:

```swift
        let keyList = ai.summarize ? "'title', 'content', and 'summary'" : "'title' and 'content'"
        parts.append(
            "You are an AI assistant that processes article content. "
            + "You will receive an article title and content in HTML format. "
            + "You must return the result as a JSON object with keys \(keyList). "
            + "Do not include any markdown formatting (like ```json) in the response, just the raw JSON string."
        )
```

Replace the summarize block (lines 84-86) so it describes the additive summary:

```swift
        if ai.summarize {
            parts.append(
                ArticleAIText.summarizeInstruction
                + " Put this summary in the 'summary' key. "
                + "Keep the 'content' field as the full article HTML — do not replace the content with the summary."
            )
        }
```

- [ ] **Step 4: Update `process` to capture the summary**

In `Yana/Services/AIProcessor.swift`, in the `do` block (lines 61-64), add the summary assignment:

```swift
                var updated = article
                if let title = parsed["title"] as? String { updated.title = title }
                if let content = parsed["content"] as? String { updated.content = content }
                if let summary = parsed["summary"] as? String { updated.summary = summary }
                output.append(updated)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorSummaryTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AIProcessor.swift YanaTests/AIProcessorSummaryTests.swift
git commit -m "feat(ai): request summary additively in cloud AIProcessor"
```

---

### Task 8: Apple Intelligence — produce summary separately, preserve body

**Files:**
- Modify: `Yana/Services/AppleIntelligenceProcessor.swift` (`processOne` and instruction helpers)
- Test: `YanaTests/AppleIntelligenceSummaryTests.swift` (create)

**Interfaces:**
- Consumes: `AggregatedArticle.summary` (Task 6), `ArticleGenerating` (existing protocol used by `generator`).
- Produces: when `ai.summarize` is on, `processOne` runs a dedicated summarization pass into `updated.summary` and does NOT collapse `content`; content reflects improve/translate only (or stays original when neither is on).

Note: the content-transform pass (`improveWriting`/`translate`) is unchanged in spirit but must drop the summarize instruction so the body keeps full length. The summary is a separate generation whose `result.content` is the summary text.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AppleIntelligenceSummaryTests.swift`. Inspect the existing `ArticleGenerating` protocol and any existing fake in `YanaTests/` (search for `ArticleGenerating` / `availability`); reuse that fake. The test below assumes a fake conforming to `ArticleGenerating` that returns canned `(title, content)` and reports `.available`. If an existing fake exists in the test target, use it; otherwise define one inline as shown:

```swift
import Foundation
import Testing
@testable import Yana

private struct FakeGenerator: ArticleGenerating {
    let availability: ArticleGeneratorAvailability = .available
    let contentReply: String
    let summaryReply: String
    // Returns summaryReply for the dedicated summary pass, contentReply otherwise.
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> (title: String, content: String) {
        if instructions.contains("summary") || instructions.contains("Summarize") {
            return (title: "T", content: summaryReply)
        }
        return (title: "T", content: contentReply)
    }
    func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
}

struct AppleIntelligenceSummaryTests {
    @Test func summarizeProducesSeparateSummaryAndKeepsBody() async {
        let gen = FakeGenerator(contentReply: "<p>full body</p>", summaryReply: "short summary")
        let processor = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 200)
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let input = AggregatedArticle(title: "T", identifier: "id", url: "u", rawContent: "",
                                      content: "<p>original body</p>", date: .now, author: "", iconURL: nil)
        let out = await processor.process([input], ai: ai)
        #expect(out.count == 1)
        #expect(out.first?.summary == "short summary")
        // Summarize alone must not rewrite the body.
        #expect(out.first?.content == "<p>original body</p>")
    }
}
```

Verify the real protocol/enum names (`ArticleGenerating`, the availability type, the `generate(...)` signature, `tokenCount`) against `Yana/Services/` before running — adjust the fake to match exactly.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppleIntelligenceSummaryTests`
Expected: FAIL — current `processOne` summarizes into `content` and leaves `summary` empty.

- [ ] **Step 3: Rework `processOne`**

In `Yana/Services/AppleIntelligenceProcessor.swift`, replace `processOne` (the whole method) with:

```swift
    private func processOne(_ article: AggregatedArticle, ai: AIOptions) async throws -> AggregatedArticle {
        let clean = ArticleAIText.cap((try? ArticleAIText.stripChrome(article.content)) ?? article.content)

        var title = article.title
        var content = article.content

        // Content pass: only when the body is actually being rewritten (improve/translate).
        // Summarize no longer modifies the body — it produces a separate summary below.
        if ai.improveWriting || ai.translate {
            let instructions = Self.contentInstructions(ai: ai)
            let chunks = ArticleChunker.chunk(html: clean,
                                              budgetTokens: Self.contentBudgetTokens,
                                              tokenCount: generator.tokenCount)
            var mapped: [String] = []
            for (i, chunk) in chunks.enumerated() {
                let result = try await generator.generate(
                    instructions: instructions,
                    prompt: Self.prompt(title: article.title, html: chunk),
                    temperature: temperature,
                    maxTokens: maxTokens
                )
                if i == 0 { title = result.title }
                mapped.append(result.content)
            }
            content = mapped.joined(separator: "\n")
        }

        var updated = article
        updated.title = title
        updated.content = content

        // Summary pass: chunk + map + reduce over the (possibly transformed) content.
        if ai.summarize {
            updated.summary = try await summarize(html: content, title: title)
        }
        return updated
    }

    /// Summarize HTML via chunk → per-chunk summary → reduce into one summary string.
    private func summarize(html: String, title: String) async throws -> String {
        let clean = ArticleAIText.cap((try? ArticleAIText.stripChrome(html)) ?? html)
        let chunks = ArticleChunker.chunk(html: clean,
                                          budgetTokens: Self.contentBudgetTokens,
                                          tokenCount: generator.tokenCount)
        var partials: [String] = []
        for chunk in chunks {
            let result = try await generator.generate(
                instructions: Self.summaryInstructions,
                prompt: Self.prompt(title: title, html: chunk),
                temperature: temperature,
                maxTokens: maxTokens
            )
            partials.append(result.content)
        }
        guard partials.count > 1 else { return partials.first ?? "" }
        let reduced = try await generator.generate(
            instructions: Self.reduceInstructions,
            prompt: Self.prompt(title: title, html: ArticleAIText.cap(partials.joined(separator: "\n"))),
            temperature: temperature,
            maxTokens: maxTokens
        )
        return reduced.content
    }
```

Replace the `instructions(ai:)` helper with a content-only variant and add a summary-only one. Replace the `static func instructions(ai:)` (and keep `reduceInstructions`):

```swift
    // MARK: - Prompt assembly (guided generation: no JSON-format boilerplate needed)

    /// Instructions for the body-rewrite pass — improve/translate only. Summarize is handled
    /// by a separate pass so the body is never collapsed into a summary.
    static func contentInstructions(ai: AIOptions) -> String {
        var parts = ["You process article content provided as HTML. "
            + "Preserve all HTML tags and structure in the content you return."]
        if ai.improveWriting { parts.append(ArticleAIText.improveWritingInstruction) }
        if ai.translate {
            parts.append(ArticleAIText.translateInstruction(language: ai.translateLanguage))
        }
        return parts.joined(separator: "\n")
    }

    static let summaryInstructions =
        "You summarize article content provided as HTML. " + ArticleAIText.summarizeInstruction

    static let reduceInstructions =
        "You combine several partial article summaries into one concise summary. "
        + ArticleAIText.summarizeInstruction
```

(Remove the old `instructions(ai:)` method. If other code references it, update those references to `contentInstructions(ai:)`; search the repo to confirm none remain.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppleIntelligenceSummaryTests`
Expected: PASS

- [ ] **Step 5: Run the existing Apple Intelligence tests to catch regressions**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests 2>&1 | grep -i "appleintel\|fail" | head`
Expected: no failures from existing Apple Intelligence tests; fix any references to the removed `instructions(ai:)`.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AppleIntelligenceProcessor.swift YanaTests/AppleIntelligenceSummaryTests.swift
git commit -m "feat(ai): produce summary separately in Apple Intelligence processor"
```

---

### Task 9: Render the summary block between header and body

**Files:**
- Modify: `Yana/Reader/ArticleRenderer.swift` (`articleSubstitutions` around line 46)
- Modify: `Yana/Resources/ArticleRendering/core.css` (append summary rules — `core.css` is prepended to every theme)
- Test: `YanaTests/ArticleRendererSummaryTests.swift` (create)

**Interfaces:**
- Consumes: `Article.summary` (Task 6).
- Produces: when `article.summary` is non-empty, the `[[body]]` substitution is `<div class="yana-summary">…</div>` + `article.content`; when empty, it equals `article.content` exactly. A localized `summaryLabel` is used for the block heading.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleRendererSummaryTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
struct ArticleRendererSummaryTests {
    @Test func bodyIncludesSummaryBlockWhenPresent() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "the summary")
        #expect(html.contains("yana-summary"))
        #expect(html.contains("the summary"))
        // Summary appears before the body content.
        let summaryRange = html.range(of: "the summary")
        let bodyRange = html.range(of: "<p>body</p>")
        #expect(summaryRange != nil && bodyRange != nil)
        #expect(summaryRange!.lowerBound < bodyRange!.lowerBound)
    }

    @Test func bodyIsContentOnlyWhenSummaryEmpty() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "")
        #expect(html == "<p>body</p>")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleRendererSummaryTests`
Expected: FAIL — `composeBody` does not exist (compile error).

- [ ] **Step 3: Add `composeBody` and use it in substitutions**

In `Yana/Reader/ArticleRenderer.swift`, add a static helper (place it in the `// MARK: - Substitutions` area, e.g. after `articleSubstitutions`):

```swift
    /// The body HTML for the `[[body]]` macro: the article content, optionally preceded by a
    /// styled summary block (rendered between the header/title and the article body). HTML-escapes
    /// the summary text since the model returns it as plain text / simple HTML; wrapping in a
    /// `<div>` keeps it isolated from the body markup.
    static func composeBody(content: String, summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }
        let label = ContentFormatter.escapeHTML(String(localized: "Summary"))
        let escaped = ContentFormatter.escapeHTML(trimmed)
        return "<div class=\"yana-summary\"><div class=\"yana-summary-label\">\(label)</div>\(escaped)</div>"
            + content
    }
```

Then change the body substitution (line 46) from:

```swift
        d["body"] = article.content
```

to:

```swift
        d["body"] = Self.composeBody(content: article.content, summary: article.summary)
```

- [ ] **Step 4: Add the CSS**

Append to `Yana/Resources/ArticleRendering/core.css`:

```css
/* Yana AI summary block — rendered between the article header and body. */
.yana-summary {
	border-left: 4px solid rgba(40, 97, 227, 0.9);
	background: rgba(127, 127, 127, 0.10);
	padding: 0.7em 0.95em;
	margin: 0 0 1.4em 0;
	border-radius: 5px;
	font-size: 0.95em;
}

.yana-summary-label {
	font-weight: 700;
	text-transform: uppercase;
	letter-spacing: 0.05em;
	font-size: 0.72em;
	opacity: 0.6;
	margin-bottom: 0.35em;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleRendererSummaryTests`
Expected: PASS

- [ ] **Step 6: Add the "Summary" translation**

In `Yana/Resources/Localizable.xcstrings`, add a `Summary` key with German `Zusammenfassung`, state `translated`. (Done thoroughly in Task 11; add it here so the renderer string is covered and re-verify in Task 11.)

- [ ] **Step 7: Commit**

```bash
git add Yana/Reader/ArticleRenderer.swift Yana/Resources/ArticleRendering/core.css Yana/Resources/Localizable.xcstrings YanaTests/ArticleRendererSummaryTests.swift
git commit -m "feat(reader): render AI summary block between header and body"
```

---

### Task 10: Provider-dependent Settings UI + new provider config

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift` (state 19-31; `loadSecrets` 318-325; `aiProviderSection` 166-232)
- Test: manual (SwiftUI view; no unit test). Build must succeed and the section must render only the selected provider.

**Interfaces:**
- Consumes: new providers + `baseURL` (Task 1), Keychain items + model settings (Task 2), `CredentialTester.ai` (Task 5).
- Produces: `aiProviderSection` shows the provider `Picker` and, below it, only the selected provider's config (key, model, optional API-URL, Test). Keys for all providers still load/save to Keychain.

- [ ] **Step 1: Add state for the new providers' keys and statuses**

In `Yana/Views/Config/SettingsScreenView.swift`, after `@State private var geminiKey = ""` (line 24):

```swift
    @State private var mistralKey = ""
    @State private var qwenKey = ""
    @State private var deepseekKey = ""
```

After `@State private var geminiStatus: TestStatus = .idle` (line 30):

```swift
    @State private var mistralStatus: TestStatus = .idle
    @State private var qwenStatus: TestStatus = .idle
    @State private var deepseekStatus: TestStatus = .idle
```

- [ ] **Step 2: Load the new keys**

In `loadSecrets()` (after line 324):

```swift
        geminiKey = KeychainService.loadAPIKey(for: .geminiAPIKey) ?? ""
        mistralKey = KeychainService.loadAPIKey(for: .mistralAPIKey) ?? ""
        qwenKey = KeychainService.loadAPIKey(for: .qwenAPIKey) ?? ""
        deepseekKey = KeychainService.loadAPIKey(for: .deepseekAPIKey) ?? ""
```

- [ ] **Step 3: Replace `aiProviderSection` with a provider-switched layout**

Replace the whole `aiProviderSection` (lines 166-232) with:

```swift
    private var aiProviderSection: some View {
        Section("AI Provider") {
            Picker(selection: $settings.activeAIProvider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            } label: {
                Label("Active Provider", systemImage: "sparkles")
                    .labelStyle(.tintedIcon(.purple))
            }

            providerConfig
        }
    }

    /// Detailed config for the currently-selected provider only (mirrors AggregatorOptionsForm's
    /// switch-on-type). `.none` shows nothing; keys for other providers stay in the Keychain.
    @ViewBuilder
    private var providerConfig: some View {
        switch settings.activeAIProvider {
        case .none:
            EmptyView()
        case .openai:
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
        case .anthropic:
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
        case .gemini:
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
        case .mistral:
            SecureField("API Key", text: $mistralKey)
                .onChange(of: mistralKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .mistralAPIKey); mistralStatus = .idle
                }
            Picker("Model", selection: $settings.mistralModel) {
                ForEach(AIProvider.mistral.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: mistralStatus, disabled: mistralKey.isEmpty) {
                runTest({ mistralStatus = $0 }) {
                    await CredentialTester.ai(provider: .mistral, apiKey: mistralKey,
                                              model: settings.mistralModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .qwen:
            SecureField("API Key", text: $qwenKey)
                .onChange(of: qwenKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .qwenAPIKey); qwenStatus = .idle
                }
            Picker("Model", selection: $settings.qwenModel) {
                ForEach(AIProvider.qwen.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: qwenStatus, disabled: qwenKey.isEmpty) {
                runTest({ qwenStatus = $0 }) {
                    await CredentialTester.ai(provider: .qwen, apiKey: qwenKey,
                                              model: settings.qwenModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .deepseek:
            SecureField("API Key", text: $deepseekKey)
                .onChange(of: deepseekKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .deepseekAPIKey); deepseekStatus = .idle
                }
            Picker("Model", selection: $settings.deepseekModel) {
                ForEach(AIProvider.deepseek.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: deepseekStatus, disabled: deepseekKey.isEmpty) {
                runTest({ deepseekStatus = $0 }) {
                    await CredentialTester.ai(provider: .deepseek, apiKey: deepseekKey,
                                              model: settings.deepseekModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .appleIntelligence:
            LabeledContent("Status", value: appleIntelligenceStatus)
            testControls(status: appleStatus, disabled: false) {
                let available = AppleIntelligenceClient().availability == .available
                appleStatus = available ? .valid : .invalid(appleIntelligenceStatus)
            }
        }
    }
```

- [ ] **Step 4: Build to verify it compiles and renders**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift
git commit -m "feat(settings): show AI config for the selected provider only; add new providers"
```

---

### Task 11: Translations, full-suite verification, and docs

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings`
- Modify: `CLAUDE.md` (AI provider lines), `README.md` if it lists providers
- Test: full suite.

**Interfaces:** none (finalization).

- [ ] **Step 1: Add/verify all new user-facing strings in the catalog**

In `Yana/Resources/Localizable.xcstrings`, ensure each of these keys exists with a German translation marked `"state" : "translated"`:

- `"Summary"` → `"Zusammenfassung"` (added in Task 9 — confirm present)
- Provider display names `"Mistral"`, `"Qwen"`, `"DeepSeek"` — these come from `displayName` literals used as `Text`. Add catalog entries with identical German values (proper nouns, untranslated): `"Mistral"` → `"Mistral"`, `"Qwen"` → `"Qwen"`, `"DeepSeek"` → `"DeepSeek"`, each `"state" : "translated"`.

The existing `"API Key"`, `"Model"`, `"API URL"`, `"Test"`, `"Active Provider"`, `"Status"` strings are reused from the previous UI — confirm they already have `de` entries (they should). Add any that are missing.

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests PASS (including pre-existing suites).

- [ ] **Step 3: Update docs**

In `CLAUDE.md`, update the AI description so the provider list reads (OpenAI/Anthropic/Gemini/Mistral/Qwen/DeepSeek), and note that the summary is rendered as its own block between the article header and body, and that the Settings AI config is shown per selected provider. Search for "OpenAI/Anthropic/Gemini" and update each occurrence. Update `README.md` similarly if it enumerates providers.

- [ ] **Step 4: Commit**

```bash
git add Yana/Resources/Localizable.xcstrings CLAUDE.md README.md
git commit -m "docs: document new AI providers, per-provider config, and summary block; add translations"
```

---

## Self-Review

**Spec coverage:**
- New providers (Mistral/Qwen/DeepSeek) → Tasks 1–5, 10. ✓
- OpenAI-compatible routing → Task 3. ✓
- Provider-dependent Settings UI → Task 10. ✓
- Summary between header and body (additive field) → Tasks 6, 7, 8, 9. ✓
- Apple Intelligence parity → Task 8. ✓
- Translations + docs → Task 11 (+ Task 9 for "Summary"). ✓
- SwiftData migration safety (defaulted `summary`) → Task 6. ✓

**Type consistency:**
- `AIConfig.openaiAPIURL` → `apiBaseURL` renamed in Task 3; all three call sites (AIClient, makeAIConfig, CredentialTester) updated in Tasks 3–5. ✓
- `composeBody(content:summary:)` defined in Task 9 and used by the renderer + tests. ✓
- `AggregatedArticle.summary` / `Article.summary` / `Article.init(summary:)` consistent across Tasks 6–8. ✓
- `CredentialTester.aiBaseURL(provider:openaiAPIURL:)` defined and used in Task 5. ✓
- `AppleIntelligenceProcessor.contentInstructions(ai:)` replaces `instructions(ai:)`; `summaryInstructions`/`reduceInstructions` defined in Task 8. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. Two tasks (8, 9) flag verifying real protocol/initializer names against the codebase before running — that is a verification instruction, not a placeholder.

**Note for implementer:** Tasks 1→10 build incrementally; the project may not fully compile between Task 3 and Task 5 if those call-site edits are split — Task 3 explicitly includes the minimal call-site fixes so each task ends compiling. Run the per-task `-only-testing` command at each step; run the full suite in Task 11.
