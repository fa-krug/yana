# Yana Server-API Client Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework Yana iOS/Mac from a self-contained, on-device aggregator into a thin, offline-first client of `yana-server`'s `/api/v1` — sign-in via device pairing, full sync (content + images, not just metadata), star/reload/update via the API, two AI modes (Server-mediated, Apple Intelligence on-device), and feed/tag/settings management moved into an in-app WebView.

**Architecture:** A new `Yana/Networking/` layer (`YanaAPIClient`) talks to the server. A new `SyncEngine` replaces `AggregationService` as the write path into the existing SwiftData store — `ArticleStore`'s observer machinery is untouched, since it only cares about `ModelContext.didSave`, not who wrote. All on-device scraping/parsing/AI-provider code is deleted, not kept as a fallback. Existing reader/timeline/block-rendering code is preserved almost entirely as-is.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, `URLSession`, `WKWebView` (device pairing + management UI), Swift Testing (`@Test`/`#expect`), FoundationModels (Apple Intelligence, unchanged).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-05-server-api-client-rework-design.md` — every task below implements a specific part of it; constraints here are the ones that apply project-wide.
- **Offline-first.** Sync eagerly pulls full article content and every referenced image, not just summaries. Lazy fetch-on-render is only a safety-net fallback for a not-yet-completed backfill, never the primary path.
- **No new server write endpoints.** Feed/tag/settings CRUD stays server-web-UI-only, reached via an in-app WebView. Only read endpoints are used from native code, plus the new `POST /api/v1/ai/prompt`.
- **Fresh start on sign-in.** No local-data import path — matches the server's own designed assumption and the already-shipped pre-2.0 migration notice.
- Swift Testing conventions (confirmed from the existing suite): `import Testing`, `@testable import Yana`, `@Suite("Name")` on a `struct`, `@Test func camelCaseName()` (no `test` prefix), `#expect(...)`, `@MainActor` on suites touching main-actor state, manual `defer { cleanup() }` for stateful round-trips (no `setUp`/`tearDown`).
- Every new persisted `AppSettings` property follows the existing `Key` enum + `access(keyPath:)`/`withMutation(keyPath:)` pattern (see Task 3).
- Localize every new user-facing string in `Yana/Resources/Localizable.xcstrings` (English + German, `"state": "translated"`) per `CLAUDE.md`'s translation rule. Steps below call this out per task where new UI copy is introduced; treat it as part of that task's "done," not a separate pass.
- Run `xcodegen generate` after any file add/remove under `Yana/` before building, since the Xcode project is generated from `project.yml`'s file globs.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build` / `... test`. Run after every task.

---

## File Structure

New files:
- `Yana/Networking/YanaAPIClient.swift` — typed `/api/v1/**` client over `URLSession`.
- `Yana/Networking/YanaAPIError.swift` — error envelope + typed error.
- `Yana/Networking/BlockWireDecoding.swift` — custom `Decodable` for `Block`/`InlineRun`/`Embed` matching the server's actual wire format (see Task 5 — this is **not** optional, the two sides' JSON shapes do not match today).
- `Yana/Services/DevicePairing.swift` — pure, testable pairing state machine (state generation/verification, callback URL parsing).
- `Yana/Views/DevicePairingView.swift` — `WKWebView` wrapper driving the pairing flow.
- `Yana/Services/SyncWriter.swift` — `@ModelActor` write path (upserts summaries/content/images, applies removals) — the `SyncEngine`'s `AggregationWriter` analog.
- `Yana/Services/SyncEngine.swift` — orchestrator: cursor, pagination, bounded-concurrency content/image fetch, backfill.
- `Yana/Services/ArticleActions.swift` — thin façade for star/reload/update-all API calls used by UI code.
- `Yana/Services/AISummaryProvider.swift` — protocol + `ServerAISummaryProvider` + `AppleIntelligenceSummaryProvider`.
- `Yana/Views/Config/Settings/AIModeSettingsSection.swift` — new 2-option AI mode picker.
- `Yana/Views/ManagementWebView.swift` — feed/tag/settings WebView screen.
- `Yana/Views/Onboarding/OnboardingServerPage.swift`, `Yana/Views/Onboarding/OnboardingAIModePage.swift` — replace the old onboarding pages (`WelcomeView.swift` keeps `WelcomeIntroPage`, drops `OnboardingAIPage`/`OnboardingFeedsPage`).

Relocated (moved out of `Yana/Aggregators/`, which is deleted once empty):
- `Yana/Aggregators/ArticleSearch.swift` → `Yana/Services/ArticleSearch.swift`
- `Yana/Aggregators/Utils/ArticleHeaderLogo.swift` → `Yana/Services/ArticleHeaderLogo.swift`
- `Yana/Aggregators/Utils/ImageStore.swift` → `Yana/Services/ImageStore.swift` (reworked, Task 11)
- `Yana/Aggregators/Utils/ReaderWeb.swift` → `Yana/Reader/ReaderWeb.swift`

Modified (existing files whose responsibilities change):
- `Yana/Models/Article.swift` — `starred: Bool` stored property, `hasContent: Bool`, remove tag-based starring.
- `Yana/Models/Feed.swift` — `logoImageHash`, `aggregator: String`, remove `AggregatorType`/`AggregatorOptions` coupling.
- `Yana/Models/Tag.swift` — remove `isBuiltIn`/`ensureBuiltIns`/`starredName`.
- `Yana/Models/ArticleSummary.swift` — remove `uid`.
- `Yana/Models/AppSettings.swift` — remove `AIProvider`/per-provider settings/Reddit/YouTube settings; add `aiMode`, `serverBaseURL`, `syncCursor`, `starredOnly`.
- `Yana/Services/KeychainService.swift` — remove `APIKeyItem`/sync-migration machinery; add device-token storage.
- `Yana/Services/CredentialTester.swift` — remove `reddit`/`youtube`/`ai`, keep `CredentialTestError`.
- `Yana/Services/BackgroundRefreshManager.swift` — call `SyncEngine` instead of `AggregationService`.
- `Yana/Services/ArticleStore.swift` — drop the now-fully-inert CloudKit remote-change observer (found during research: harmless dead code left over from CloudKit removal, since the store is no longer CloudKit-mirrored at all).
- `Yana/Views/TagFilterView.swift` — add a "Starred" boolean quick-filter row.
- `Yana/Views/Config/SettingsScreenView.swift`, `Yana/Reader/Mac/MacSettingsWindow.swift` — drop Feeds/Tags/Integrations/AI-provider/AI-tuning sections/panes, add AI mode + server/pairing + WebView entry point.
- `Yana/Views/WelcomeView.swift` — 3 steps: welcome / server+pairing / AI mode.
- `Yana/ContentView.swift` — re-pairing gate alongside the onboarding gate.
- `Yana/Reader/ReaderHostView.swift`, `Yana/Reader/Mac/MacRootView.swift` — "add feed" quick action opens the management WebView instead of `FeedEditorView`.

Deleted outright (verified redundant against the new architecture — exact list, not "the rest of the folder"):
- `Yana/Aggregators/AggregatedArticle.swift`, `AggregationLogic.swift`, `Aggregator.swift`, `AggregatorRegistry.swift`, `AggregatorType.swift`, `ArticleUpsert.swift`, `FeedConfig.swift`, `FeedLogoResolver.swift`, `RetentionCleanup.swift`
- `Yana/Aggregators/Concrete/` (entire directory — 16 scrapers + Reddit/YouTube clients/models/markdown)
- `Yana/Aggregators/Utils/BlockParser.swift`, `BlueskyEmbed.swift`, `ContentFormatter.swift`, `DomainImageOverrides.swift`, `EmbedRewriter.swift`, `FaviconResolver.swift`, `FeedDiscovery.swift`, `FeedParser.swift`, `FeedURLResolver.swift`, `HTMLUtils.swift`, `HeaderElementExtractor.swift`, `ImageCompressor.swift`, `LogoBackgroundRemover.swift`
- `Yana/Aggregators/Utils/HTTPClient.swift` (its two constants — `maxImageResponseBytes`, `imageAccept` — move into `Yana/Networking/YanaAPIClient.swift`, Task 11; the rest, generic scraping-fetch code, is deleted)
- `Yana/Services/AggregationService.swift`, `AggregationWriter.swift`, `StarredRegistry.swift`, `ArticleUID.swift`, `LibraryDedup.swift`, `ImageSync.swift`, `ImagePrune.swift` (+ its candidate-quarantine store file), `AIClient.swift`, `AIProcessor.swift`, `FeedPortability.swift`, `OPMLCodec.swift`
- `Yana/Models/AggregatorOptions.swift`
- `Yana/Views/Config/FeedsView.swift`, `TagsView.swift`, `FeedEditorView.swift`, `FeedTagsPicker.swift` (if a separate file), `TagEditorView.swift`, `AggregatorOptionsForm.swift`
- `Yana/Views/Config/Settings/RedditSettingsSection.swift`, `YouTubeSettingsSection.swift`, `AIProviderSettingsSection.swift`, `AITuningSettingsSection.swift`
- `Yana/Services/AIReadiness.swift`, `Yana/Views/Config/SelectorListView.swift`, `Yana/Services/SelectorSuggester.swift` (+ their test files — found during Task 3's execution, not the original inventory; see Tasks 15/19's Files lists for why each is dead)

---

## Phase 1 — Networking + auth foundation

### Task 1: `YanaAPIClient` core

**Files:**
- Create: `Yana/Networking/YanaAPIError.swift`
- Create: `Yana/Networking/YanaAPIClient.swift`
- Test: `YanaTests/YanaAPIClientTests.swift`

**Interfaces:**
- Produces: `struct YanaAPIError: Error, Equatable { let code: String; let message: String }`, `enum YanaAPIClientError: Error, Equatable { case transport, decoding, server(YanaAPIError), unauthorized }`, `struct YanaAPIClient: Sendable` with `init(baseURL: URL, token: String, session: URLSession = .shared)` and `func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T`, `func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T`, `func post<T: Decodable>(_ path: String, body: (some Encodable)? = nil) async throws -> T`, `func getRaw(_ path: String) async throws -> (Data, HTTPURLResponse)`.

- [ ] **Step 1: Write the failing test for the error envelope decode**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("YanaAPIClient")
struct YanaAPIClientTests {
    private func mockClient(status: Int, body: Data, session: URLSession? = nil) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "test-token", session: URLSession(configuration: config))
    }

    @Test func decodesAServerErrorEnvelopeOn404() async {
        let body = #"{"error":{"code":"not_found","message":"Article not found."}}"#.data(using: .utf8)!
        let client = mockClient(status: 404, body: body)
        struct Empty: Decodable {}
        await #expect(throws: YanaAPIClientError.server(YanaAPIError(code: "not_found", message: "Article not found."))) {
            let _: Empty = try await client.get("/api/v1/articles/999")
        }
    }

    @Test func decodesASuccessfulResponse() async throws {
        struct Feeds: Decodable, Equatable { let feeds: [String] }
        let body = #"{"feeds":[]}"#.data(using: .utf8)!
        let client = mockClient(status: 200, body: body)
        let result: Feeds = try await client.get("/api/v1/feeds")
        #expect(result == Feeds(feeds: []))
    }

    @Test func attachesTheBearerToken() async throws {
        var capturedAuth: String?
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
        }
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "abc123", session: URLSession(configuration: config))
        struct Feeds: Decodable { let feeds: [String] }
        let _: Feeds = try await client.get("/api/v1/feeds")
        #expect(capturedAuth == "Bearer abc123")
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let stub = Self.stub else { return }
        let (response, data) = stub(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YanaAPIClientTests`
Expected: FAIL — `YanaAPIClient`/`YanaAPIError`/`YanaAPIClientError` don't exist yet.

- [ ] **Step 3: Write `YanaAPIError.swift`**

```swift
import Foundation

/// Mirrors the server's `{ "error": { "code": "...", "message": "..." } }` envelope,
/// present on every non-2xx `/api/v1/**` response.
struct YanaAPIError: Error, Equatable, Decodable {
    let code: String
    let message: String
}

private struct YanaAPIErrorEnvelope: Decodable {
    let error: YanaAPIError
}

enum YanaAPIClientError: Error, Equatable {
    case transport
    case decoding
    case unauthorized
    case server(YanaAPIError)
}
```

- [ ] **Step 4: Write `YanaAPIClient.swift`**

```swift
import Foundation

/// Thin typed wrapper over every `/api/v1/**` route. Attaches the caller's Bearer token to
/// every request; decodes the server's `{ error: { code, message } }` envelope on failure.
struct YanaAPIClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(path: path, method: "GET", query: query, body: Optional<Never>.none)
    }

    func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await send(path: path, method: "PATCH", query: [:], body: body)
    }

    func post<T: Decodable>(_ path: String, body: (some Encodable)? = nil) async throws -> T {
        try await send(path: path, method: "POST", query: [:], body: body)
    }

    /// Raw bytes for a binary response (used for `/images/:hash`), skipping JSON decode.
    func getRaw(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(path: path, method: "GET", query: [:])
        let (data, response) = try await performRequest(request)
        return (data, response)
    }

    private func send<T: Decodable, Body: Encodable>(
        path: String, method: String, query: [String: String], body: Body?
    ) async throws -> T {
        var request = try makeRequest(path: path, method: method, query: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await performRequest(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw YanaAPIClientError.unauthorized }
            guard let envelope = try? JSONDecoder().decode(YanaAPIErrorEnvelopeDecoder.self, from: data) else {
                throw YanaAPIClientError.transport
            }
            throw YanaAPIClientError.server(envelope.error)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw YanaAPIClientError.decoding
        }
        return decoded
    }

    private func makeRequest(path: String, method: String, query: [String: String]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw YanaAPIClientError.transport
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw YanaAPIClientError.transport }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw YanaAPIClientError.transport }
            return (data, http)
        } catch let error as YanaAPIClientError {
            throw error
        } catch {
            throw YanaAPIClientError.transport
        }
    }
}

private struct YanaAPIErrorEnvelopeDecoder: Decodable {
    let error: YanaAPIError
}
```

Note: `Optional<Never>.none` as the "no body" `Encodable` sentinel for `get` — `Never` conforms to nothing usable here, so give `send`'s generic a concrete no-op `Encodable` instead. Replace that line and the generic constraint with:

```swift
private struct NoBody: Encodable {}

func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    try await send(path: path, method: "GET", query: query, body: Optional<NoBody>.none)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YanaAPIClientTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Networking/YanaAPIError.swift Yana/Networking/YanaAPIClient.swift YanaTests/YanaAPIClientTests.swift project.yml
git commit -m "Add YanaAPIClient: typed HTTP client for yana-server's /api/v1"
```

---

### Task 2: Device pairing state machine (pure, testable)

**Files:**
- Create: `Yana/Services/DevicePairing.swift`
- Test: `YanaTests/DevicePairingTests.swift`

**Interfaces:**
- Consumes: nothing (no dependency on Task 1).
- Produces: `struct DevicePairingSession { let state: String }`, `enum DevicePairingResult: Equatable { case success(token: String); case stateMismatch; case malformedCallback }`, `enum DevicePairing { static func makeSession(randomState: () -> String = { UUID().uuidString }) -> DevicePairingSession; static func pairingURL(serverBaseURL: URL, session: DevicePairingSession, deviceName: String) -> URL; static func handleCallback(_ url: URL, session: DevicePairingSession) -> DevicePairingResult }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("DevicePairing")
struct DevicePairingTests {
    @Test func pairingURLCarriesStateSchemeAndDeviceName() {
        let session = DevicePairingSession(state: "abc-123")
        let url = DevicePairing.pairingURL(
            serverBaseURL: URL(string: "https://yana.example.com")!,
            session: session,
            deviceName: "Test iPhone"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/login")
        let next = components.queryItems?.first { $0.name == "next" }?.value ?? ""
        #expect(next.contains("state=abc-123"))
        #expect(next.contains("scheme=yana"))
        #expect(next.contains("deviceName=Test%20iPhone") || next.contains("deviceName=Test+iPhone"))
    }

    @Test func matchingStateExtractsToken() {
        let session = DevicePairingSession(state: "abc-123")
        let callback = URL(string: "yana://auth-callback?token=secret-token&state=abc-123")!
        #expect(DevicePairing.handleCallback(callback, session: session) == .success(token: "secret-token"))
    }

    @Test func mismatchedStateIsRejected() {
        let session = DevicePairingSession(state: "abc-123")
        let callback = URL(string: "yana://auth-callback?token=secret-token&state=wrong")!
        #expect(DevicePairing.handleCallback(callback, session: session) == .stateMismatch)
    }

    @Test func missingTokenOrStateIsMalformed() {
        let session = DevicePairingSession(state: "abc-123")
        let noToken = URL(string: "yana://auth-callback?state=abc-123")!
        #expect(DevicePairing.handleCallback(noToken, session: session) == .malformedCallback)
        let noState = URL(string: "yana://auth-callback?token=secret-token")!
        #expect(DevicePairing.handleCallback(noState, session: session) == .malformedCallback)
    }

    @Test func makeSessionUsesTheInjectedRandomState() {
        let session = DevicePairing.makeSession(randomState: { "fixed-value" })
        #expect(session.state == "fixed-value")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/DevicePairingTests`
Expected: FAIL — `DevicePairing` doesn't exist.

- [ ] **Step 3: Write `DevicePairing.swift`**

```swift
import Foundation

/// The in-memory state for one pairing attempt. Never persisted — a server-minted state would
/// hand an attacker a valid one too, so the defense is the client holding a secret it generated
/// and never shared (the same pattern `gh auth login --web` uses).
struct DevicePairingSession: Equatable {
    let state: String
}

enum DevicePairingResult: Equatable {
    case success(token: String)
    case stateMismatch
    case malformedCallback
}

enum DevicePairing {
    static func makeSession(randomState: () -> String = { UUID().uuidString }) -> DevicePairingSession {
        DevicePairingSession(state: randomState())
    }

    /// The URL the pairing `WKWebView` loads: the server's login page, carrying a `next` that
    /// chains into `/device/pair` once the user authenticates. The server's `/login` forwards
    /// its `next` query param through unchanged.
    static func pairingURL(serverBaseURL: URL, session: DevicePairingSession, deviceName: String) -> URL {
        var next = URLComponents()
        next.path = "/device/pair"
        next.queryItems = [
            URLQueryItem(name: "state", value: session.state),
            URLQueryItem(name: "scheme", value: "yana"),
            URLQueryItem(name: "deviceName", value: deviceName),
        ]
        let nextString = next.url?.absoluteString ?? ""

        var login = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false)!
        login.path = "/login"
        login.queryItems = [URLQueryItem(name: "next", value: nextString)]
        return login.url!
    }

    /// Called from the pairing `WKWebView`'s navigation delegate when it intercepts a
    /// `yana://auth-callback` navigation, before it becomes a network request.
    static func handleCallback(_ url: URL, session: DevicePairingSession) -> DevicePairingResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let echoedState = items.first(where: { $0.name == "state" })?.value
        else {
            return .malformedCallback
        }
        guard echoedState == session.state else { return .stateMismatch }
        return .success(token: token)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/DevicePairingTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/DevicePairing.swift YanaTests/DevicePairingTests.swift project.yml
git commit -m "Add DevicePairing: pure state machine for the pairing/auth-callback flow"
```

---

### Task 3: Keychain device-token storage, `AppSettings` additions, URL scheme registration

**Files:**
- Modify: `Yana/Services/KeychainService.swift` (whole file — simplifies significantly)
- Modify: `Yana/Models/AppSettings.swift` (remove `AIProvider` + related; add `aiMode`, `serverBaseURL`, `syncCursor`, `starredOnly`)
- Modify: `Yana/Info-iOS.plist` (add `CFBundleURLTypes`)
- Modify: `YanaTests/KeychainServiceTests.swift`
- Test: `YanaTests/AppSettingsAIModeTests.swift`

**Interfaces:**
- Produces: `KeychainService.saveDeviceToken(_ token: String) -> Bool`, `KeychainService.loadDeviceToken() -> String?`, `KeychainService.deleteDeviceToken() -> Bool`; `enum AIMode: String, CaseIterable, Sendable, Identifiable { case server, appleIntelligence }` with `AppSettings.aiMode: AIMode` (default `.server`); `AppSettings.serverBaseURL: String` (default `""`); `AppSettings.syncCursor: String?`; `AppSettings.starredOnly: Bool` (default `false`).

- [ ] **Step 1: Rewrite `KeychainService.swift`**

The device-pairing session token is inherently per-device (the server mints an independent session per paired device, revocable independently from the "Devices" list) — it must **never** sync via iCloud Keychain, unlike the old AI/Reddit/YouTube keys this file used to also manage. Since those are all gone, the `synchronizeWithICloud` flag and `migrateSynchronizable`/`resaveAllSynchronizable` machinery (which existed only to migrate *those* keys between sync states) go away too; the device token is hardcoded non-synchronizable.

```swift
import Foundation

enum KeychainService: Sendable {
    private static let deviceTokenKey = "device_session_token"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func saveDeviceToken(_ token: String) -> Bool { save(key: deviceTokenKey, value: token) }

    static func loadDeviceToken() -> String? { load(key: deviceTokenKey) }

    @discardableResult
    static func deleteDeviceToken() -> Bool { delete(key: deviceTokenKey) }
}
```

- [ ] **Step 2: Rewrite `KeychainServiceTests.swift`**

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("KeychainService")
struct KeychainServiceTests {
    @Test func deviceTokenRoundTrip() {
        KeychainService.deleteDeviceToken()
        defer { KeychainService.deleteDeviceToken() }

        let saved = KeychainService.saveDeviceToken("test-session-token")
        #expect(saved)
        #expect(KeychainService.loadDeviceToken() == "test-session-token")

        KeychainService.deleteDeviceToken()
        #expect(KeychainService.loadDeviceToken() == nil)
    }
}
```

- [ ] **Step 3: Modify `AppSettings.swift`**

Delete: the `AIProvider` enum (all 8 cases and its `displayName`/`models`/`defaultModel`/`baseURL`/`apiKeyItem`), `activeAIProvider`, `openaiAPIURL`/`openaiModel`/`anthropicModel`/`geminiModel`/`mistralModel`/`qwenModel`/`deepseekModel`, `aiTemperature`/`aiMaxTokens`/`aiMaxPromptLength`/`aiDefaultDailyLimit`/`aiDefaultMonthlyLimit`/`aiRequestTimeout`/`aiMaxRetries`/`aiRetryDelay`/`aiRequestDelay`, `aiModel(for:)`/`setAIModel(_:for:)`, `redditEnabled`/`redditUserAgent`/`youtubeEnabled`/`isSourceEnabled(_:)`, every corresponding `Key` entry and `defaults.register` default.

Add, following the existing `Key` enum + computed-property pattern exactly:

```swift
// In the Key enum:
static let aiMode = "settings.aiMode"
static let serverBaseURL = "settings.serverBaseURL"
static let syncCursor = "settings.syncCursor"
static let starredOnly = "settings.starredOnly"
```

```swift
// In init's defaults.register:
Key.aiMode: AIMode.server.rawValue,
```

```swift
// New computed properties, alongside the existing ones:

/// Which AI path produces the reader's summary block. `.server` calls
/// `POST /api/v1/ai/prompt` against whatever provider the user configured server-side;
/// `.appleIntelligence` runs entirely on-device. Device-local — never synced (mirrors
/// `updateInterval`'s reasoning: this is a per-device capability choice, not a library setting).
var aiMode: AIMode {
    get {
        access(keyPath: \.aiMode)
        guard let raw = defaults.string(forKey: Key.aiMode), let mode = AIMode(rawValue: raw) else { return .server }
        return mode
    }
    set { withMutation(keyPath: \.aiMode) { defaults.set(newValue.rawValue, forKey: Key.aiMode) } }
}

/// The paired yana-server's base URL (self-hosted software — there is no fixed host).
/// Entered during onboarding's server-configuration step, editable later in Settings.
var serverBaseURL: String {
    get { access(keyPath: \.serverBaseURL); return defaults.string(forKey: Key.serverBaseURL) ?? "" }
    set { withMutation(keyPath: \.serverBaseURL) { defaults.set(newValue, forKey: Key.serverBaseURL) } }
}

/// Opaque cursor from the last successful `/api/v1/articles/sync` call. `nil` forces a full
/// resync from scratch. Device-local network state — never synced.
var syncCursor: String? {
    get { access(keyPath: \.syncCursor); return defaults.string(forKey: Key.syncCursor) }
    set { withMutation(keyPath: \.syncCursor) { defaults.set(newValue, forKey: Key.syncCursor) } }
}

/// Timeline quick-filter: show only starred articles. Replaces the old built-in "Starred" tag
/// row now that starring is a plain boolean, not tag membership.
var starredOnly: Bool {
    get { access(keyPath: \.starredOnly); return defaults.bool(forKey: Key.starredOnly) }
    set { withMutation(keyPath: \.starredOnly) { defaults.set(newValue, forKey: Key.starredOnly) } }
}
```

Add the `AIMode` enum (new file section or top of `AppSettings.swift`, matching where `AIProvider` used to live):

```swift
enum AIMode: String, CaseIterable, Sendable, Identifiable {
    case server
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .server: String(localized: "Server")
        case .appleIntelligence: String(localized: "Apple Intelligence")
        }
    }
}
```

- [ ] **Step 4: Add the URL scheme to `Yana/Info-iOS.plist`**

Add (as a sibling of the existing top-level keys, e.g. near `UIBackgroundModes`):

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>de.fa-krug.Yana.pairing</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>yana</string>
        </array>
    </dict>
</array>
```

- [ ] **Step 5: Write the failing `AppSettingsAIModeTests.swift`, run it, confirm pass**

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AppSettings.aiMode")
struct AppSettingsAIModeTests {
    @Test func defaultsToServer() {
        let defaults = UserDefaults(suiteName: "AppSettingsAIModeTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.aiMode == .server)
    }

    @Test func roundTripsAppleIntelligence() {
        let defaults = UserDefaults(suiteName: "AppSettingsAIModeTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.aiMode = .appleIntelligence
        #expect(settings.aiMode == .appleIntelligence)
    }

    @Test func serverBaseURLDefaultsEmpty() {
        let defaults = UserDefaults(suiteName: "AppSettingsAIModeTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.serverBaseURL == "")
        settings.serverBaseURL = "https://yana.example.com"
        #expect(settings.serverBaseURL == "https://yana.example.com")
    }
}
```

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/KeychainServiceTests -only-testing:YanaTests/AppSettingsAIModeTests`
Expected: PASS. This will **not yet fully build** — `AppSettings.swift` still has call sites elsewhere in the app referencing the deleted `AIProvider`/Reddit/YouTube properties (in views not yet reworked). That's expected at this point in the plan; those call sites are removed in Tasks 15–21. Confirm at least `YanaTests` compiles and these two test targets pass in isolation; a full-app build is only required to be green again at the end of Phase 6.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/KeychainService.swift YanaTests/KeychainServiceTests.swift Yana/Models/AppSettings.swift Yana/Info-iOS.plist YanaTests/AppSettingsAIModeTests.swift
git commit -m "Replace AI-provider/Reddit/YouTube Keychain+Settings with device-token storage and AIMode"
```

---

### Task 4: Pairing WebView UI

**Files:**
- Create: `Yana/Views/DevicePairingView.swift`
- Modify: `project.yml` (no change expected — file glob already covers `Yana/Views/**`; run `xcodegen generate` regardless)

**Interfaces:**
- Consumes: `DevicePairing.makeSession()/pairingURL(...)/handleCallback(...)` (Task 2), `KeychainService.saveDeviceToken(_:)` (Task 3).
- Produces: `struct DevicePairingView: View { let serverBaseURL: URL; let onPaired: (String) -> Void; let onCancel: () -> Void }`.

This view has no automated test (a live `WKWebView` navigation against a real server isn't unit-testable) — verify manually per Step 3.

- [ ] **Step 1: Write `DevicePairingView.swift`**

```swift
import SwiftUI
import WebKit

/// Drives the device-pairing flow: loads the server's login page in a **persistent**
/// (non-ephemeral) `WKWebView` so the resulting cookie session survives for the management
/// WebView to reuse later, and intercepts the `yana://auth-callback` redirect before it becomes
/// a network request.
struct DevicePairingView: View {
    let serverBaseURL: URL
    let onPaired: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            DevicePairingWebView(serverBaseURL: serverBaseURL, onPaired: onPaired, onFailed: onCancel)
                .navigationTitle("Sign In")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
    }
}

private struct DevicePairingWebView: UIViewRepresentable {
    let serverBaseURL: URL
    let onPaired: (String) -> Void
    let onFailed: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        // Non-ephemeral `.default()` data store — cookies from this session persist across
        // launches, and the management WebView (a later task) reuses the same store so a user
        // who just paired doesn't have to log in again.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        let session = DevicePairing.makeSession()
        context.coordinator.session = session
        let deviceName = UIDevice.current.name
        webView.load(URLRequest(url: DevicePairing.pairingURL(
            serverBaseURL: serverBaseURL, session: session, deviceName: deviceName
        )))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPaired: onPaired, onFailed: onFailed) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPaired: (String) -> Void
        let onFailed: () -> Void
        var session: DevicePairingSession?

        init(onPaired: @escaping (String) -> Void, onFailed: @escaping () -> Void) {
            self.onPaired = onPaired
            self.onFailed = onFailed
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, url.scheme == "yana", let session else {
                decisionHandler(.allow)
                return
            }
            switch DevicePairing.handleCallback(url, session: session) {
            case .success(let token):
                decisionHandler(.cancel)
                onPaired(token)
            case .stateMismatch, .malformedCallback:
                decisionHandler(.cancel)
                onFailed()
            }
        }
    }
}
```

- [ ] **Step 2: Wire a temporary manual entry point for verification**

This view is fully wired into onboarding in Task 22; for now, confirm it builds and add it to `xcodegen generate`'s output by building the app target only (no test — this step just confirms compilation, since there's no runtime host yet):

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds for this file (ignore pre-existing failures from Task 3's Step 5 note — the app target overall isn't expected green until Phase 6 ends).

- [ ] **Step 3: Manual verification (defer to Task 22)**

Note in the commit message that end-to-end manual verification (load a real server's `/login`, sign in, confirm the callback fires `onPaired` with a token, confirm `KeychainService.saveDeviceToken` round-trips it) happens once Task 22 wires this into `WelcomeView` and there's a real UI path to exercise it from the Simulator.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/DevicePairingView.swift
git commit -m "Add DevicePairingView: WKWebView-driven device pairing flow"
```

---

## Phase 2 — Content wire format

### Task 5: Custom `Decodable` for the server's `Block` wire format

**This is the highest-risk task in this plan.** Confirmed by reading both codebases directly: `Yana/Reader/Block.swift`'s `Block`/`InlineRun` have **no custom `Codable`** — they rely on Swift's compiler-synthesized encoding for an enum with associated values, which produces `{"paragraph": [...]}`, `{"heading": {"level":1,"runs":[...]}}`, etc. (case name as the single JSON key). The server's actual wire format (`yana-server/src/lib/aggregators/blocks/schema.ts`, confirmed by reading `encodeDocument`/`encodeBlock`) is a conventional discriminated union: `{"type": "paragraph", "runs": [...]}`, `{"type": "heading", "level": 1, "runs": [...]}`, etc., wrapped in `{"version": 1, "blocks": [...]}`. **These do not match** — decoding a real server response with `JSONDecoder().decode([Block].self, from:)` today would throw immediately. This task adds the missing translation layer.

**Files:**
- Create: `Yana/Networking/BlockWireDecoding.swift`
- Test: `YanaTests/BlockWireDecodingTests.swift`

**Interfaces:**
- Consumes: `Block`, `InlineRun`, `InlineStyle`, `Embed` (`Yana/Reader/Block.swift`, unmodified).
- Produces: `struct WireDocument: Decodable { let version: Int; let blocks: [Block] }` (with `Block`'s wire-shaped decoding wired in via this file, so `JSONDecoder().decode(WireDocument.self, from: serverJSON)` works directly against a real `GET /articles/:id/content` response).

- [ ] **Step 1: Write the failing test using a real server response shape**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("BlockWireDecoding")
struct BlockWireDecodingTests {
    @Test func decodesAParagraphWithStyledRuns() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"paragraph","runs":[{"text":"Hello ","styles":[],"link":null},{"text":"world","styles":["bold","italic"],"link":"https://example.com"}]}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        #expect(doc.version == 1)
        guard case .paragraph(let runs) = doc.blocks.first else { Issue.record("expected paragraph"); return }
        #expect(runs[0] == InlineRun(text: "Hello ", styles: [], link: nil))
        #expect(runs[1] == InlineRun(text: "world", styles: [.bold, .italic], link: "https://example.com"))
    }

    @Test func decodesHeadingListBlockquoteDivider() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"heading","level":2,"runs":[{"text":"Title","styles":[],"link":null}]},
            {"type":"list","ordered":true,"items":[[{"type":"paragraph","runs":[{"text":"one","styles":[],"link":null}]}]]},
            {"type":"blockquote","blocks":[{"type":"paragraph","runs":[{"text":"quoted","styles":[],"link":null}]}]},
            {"type":"divider"}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        #expect(doc.blocks.count == 4)
        guard case .heading(let level, let runs) = doc.blocks[0] else { Issue.record("expected heading"); return }
        #expect(level == 2)
        #expect(runs.first?.text == "Title")
        guard case .list(let ordered, let items) = doc.blocks[1] else { Issue.record("expected list"); return }
        #expect(ordered)
        #expect(items.count == 1)
        guard case .blockquote(let inner) = doc.blocks[2] else { Issue.record("expected blockquote"); return }
        #expect(inner.count == 1)
        guard case .divider = doc.blocks[3] else { Issue.record("expected divider"); return }
    }

    @Test func decodesImageEmbedCodeBlock() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"image","ref":"yana-img://abc123","caption":[]},
            {"type":"embed","provider":"youtube","thumbnailRef":"yana-img://thumb1","externalURL":"https://youtube.com/watch?v=x","title":"A Video"},
            {"type":"codeBlock","text":"let x = 1","language":"swift"}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        guard case .image(let ref, let caption) = doc.blocks[0] else { Issue.record("expected image"); return }
        #expect(ref == "yana-img://abc123")
        #expect(caption.isEmpty)
        guard case .embed(let embed) = doc.blocks[1] else { Issue.record("expected embed"); return }
        #expect(embed.provider == .youtube)
        #expect(embed.title == "A Video")
        guard case .codeBlock(let text, let language) = doc.blocks[2] else { Issue.record("expected codeBlock"); return }
        #expect(text == "let x = 1")
        #expect(language == "swift")
    }

    @Test func unknownStyleNameIsIgnoredNotFatal() throws {
        let json = #"""
        {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"x","styles":["bold","madeUpStyle"],"link":null}]}]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        guard case .paragraph(let runs) = doc.blocks.first else { Issue.record("expected paragraph"); return }
        #expect(runs.first?.styles == [.bold])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BlockWireDecodingTests`
Expected: FAIL — `WireDocument` doesn't exist, and even a hand-rolled version would fail because `Block`/`InlineRun`/`Embed`'s synthesized `Decodable` doesn't match this JSON shape.

- [ ] **Step 3: Write `BlockWireDecoding.swift`**

```swift
import Foundation

/// The server's wire format for an article's content, matching
/// `yana-server/src/lib/aggregators/blocks/schema.ts` exactly: a `type`-discriminated union,
/// **not** the shape `Block`'s compiler-synthesized `Codable` would produce on its own (that
/// synthesis encodes each case as `{"<caseName>": ...}` with no `type` field at all). This file
/// is the translation layer — `Block`/`InlineRun`/`Embed` themselves are untouched, since the
/// reader's existing block-rendering code depends on their current in-memory shape.
struct WireDocument: Decodable {
    let version: Int
    let blocks: [Block]

    private enum CodingKeys: String, CodingKey { case version, blocks }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        blocks = try container.decode([WireBlockBox].self, forKey: .blocks).map(\.block)
    }
}

/// Decodes one server `WireBlock` object into the app's `Block` enum. A private wrapper (rather
/// than a `Block` extension) because `Block` itself must keep its existing synthesized
/// `Codable` for anything that still round-trips it in-memory (nothing currently does, but
/// changing `Block`'s own conformance is a larger, riskier edit than adding this translation
/// layer next to it).
private struct WireBlockBox: Decodable {
    let block: Block

    private enum TypeKey: String, CodingKey { case type }
    private enum ParagraphKeys: String, CodingKey { case runs }
    private enum HeadingKeys: String, CodingKey { case level, runs }
    private enum ListKeys: String, CodingKey { case ordered, items }
    private enum BlockquoteKeys: String, CodingKey { case blocks }
    private enum ImageKeys: String, CodingKey { case ref, caption }
    private enum EmbedKeys: String, CodingKey { case provider, thumbnailRef, externalURL, title }
    private enum CodeBlockKeys: String, CodingKey { case text, language }

    init(from decoder: any Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeContainer.decode(String.self, forKey: .type)
        switch type {
        case "paragraph":
            let c = try decoder.container(keyedBy: ParagraphKeys.self)
            block = .paragraph(try c.decode([WireInlineRun].self, forKey: .runs).map(\.run))
        case "heading":
            let c = try decoder.container(keyedBy: HeadingKeys.self)
            block = .heading(
                level: try c.decode(Int.self, forKey: .level),
                runs: try c.decode([WireInlineRun].self, forKey: .runs).map(\.run)
            )
        case "list":
            let c = try decoder.container(keyedBy: ListKeys.self)
            let items = try c.decode([[WireBlockBox]].self, forKey: .items)
            block = .list(ordered: try c.decode(Bool.self, forKey: .ordered), items: items.map { $0.map(\.block) })
        case "blockquote":
            let c = try decoder.container(keyedBy: BlockquoteKeys.self)
            block = .blockquote(try c.decode([WireBlockBox].self, forKey: .blocks).map(\.block))
        case "image":
            let c = try decoder.container(keyedBy: ImageKeys.self)
            block = .image(
                ref: try c.decode(String.self, forKey: .ref),
                caption: try c.decode([WireInlineRun].self, forKey: .caption).map(\.run)
            )
        case "embed":
            let c = try decoder.container(keyedBy: EmbedKeys.self)
            let providerRaw = try c.decode(String.self, forKey: .provider)
            block = .embed(Embed(
                provider: Embed.Provider(rawValue: providerRaw) ?? .generic,
                thumbnailRef: try c.decodeIfPresent(String.self, forKey: .thumbnailRef),
                externalURL: try c.decode(String.self, forKey: .externalURL),
                title: try c.decodeIfPresent(String.self, forKey: .title)
            ))
        case "codeBlock":
            let c = try decoder.container(keyedBy: CodeBlockKeys.self)
            block = .codeBlock(
                text: try c.decode(String.self, forKey: .text),
                language: try c.decodeIfPresent(String.self, forKey: .language)
            )
        case "divider":
            block = .divider
        default:
            // Server's own extensibility rule: an unknown block type is skipped, never fatal.
            // Represent it as an empty paragraph rather than failing the whole document decode.
            block = .paragraph([])
        }
    }
}

private struct WireInlineRun: Decodable {
    let run: InlineRun

    private enum CodingKeys: String, CodingKey { case text, styles, link }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .text)
        let link = try c.decodeIfPresent(String.self, forKey: .link)
        let styleNames = try c.decode([String].self, forKey: .styles)
        var styles: InlineStyle = []
        for name in styleNames {
            switch name {
            case "bold": styles.insert(.bold)
            case "italic": styles.insert(.italic)
            case "code": styles.insert(.code)
            case "strikethrough": styles.insert(.strikethrough)
            default: break   // unknown style name ignored, per the server's own extensibility rule
            }
        }
        run = InlineRun(text: text, styles: styles, link: link)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BlockWireDecodingTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/BlockWireDecoding.swift YanaTests/BlockWireDecodingTests.swift
git commit -m "Add WireDocument: decode the server's type-discriminated Block JSON

Block's own Codable is compiler-synthesized and does not match the
server's {type: \"paragraph\", ...} wire format at all -- this was a
silent decode-failure risk that would have surfaced only against a
real server response."
```

---

## Phase 3 — Data model changes

### Task 6: `Article.starred: Bool`, delete `StarredRegistry`, add a Starred quick-filter

**Files:**
- Modify: `Yana/Models/Article.swift`
- Modify: `Yana/Models/Tag.swift`
- Delete: `Yana/Services/StarredRegistry.swift`
- Modify: `Yana/Views/TagFilterView.swift`
- Test: `YanaTests/ArticleStarredTests.swift`

**Interfaces:**
- Produces: `Article.starred: Bool` (stored, default `false`), replacing computed `isStarred`/`setStarred(_:using:)`.

- [ ] **Step 1: Find the article-list filter predicate before touching anything**

Run: `grep -rn "disabledTagNames\|disabledFeedNames\|includeUntagged" Yana --include="*.swift"`

This locates every place that reads `AppSettings`'s filter flags to build the actual article-visibility predicate (confirmed to exist outside `TagFilterView.swift` itself, per prior research) — record the file:line here before Step 5, since that predicate needs a `starredOnly` branch added.

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Article.starred")
struct ArticleStarredTests {
    @Test func defaultsToFalseAndIsMutable() throws {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let article = Article(title: "Test", identifier: "id-1", url: "https://example.com")
        context.insert(article)
        #expect(article.starred == false)
        article.starred = true
        #expect(article.starred == true)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStarredTests`
Expected: FAIL — `Article` has no `starred` property (only computed `isStarred`).

- [ ] **Step 4: Modify `Article.swift`**

Replace:
```swift
/// Snapshot of the feed's tags at import, plus the built-in Starred tag when starred.
var tags: [Tag]?
```
with:
```swift
var starred: Bool = false
/// Whether this article's content has been synced yet (`false` right after its summary
/// arrives from `/articles/sync`, `true` once `/articles/:id/content` succeeds). Drives the
/// sync engine's content-backfill retry, not just a display flag.
var hasContent: Bool = false
```

Delete `isStarred`/`setStarred(_:using:)` entirely (lines 84–99 per the earlier research pass). Any remaining call site of `.isStarred`/`.setStarred` is expected to fail to compile until Tasks 9–12 rewire the write path — that's fine at this point in the plan; those are on-device-aggregation call sites being deleted anyway.

- [ ] **Step 5: Modify `Tag.swift`**

Delete `isBuiltIn`, `sortOrder`'s built-in-tag-specific `-1` convention comment (keep `sortOrder` itself — tags still need manual ordering), `starredName`, and `ensureBuiltIns(in:)` entirely. `Tag` becomes: `name`, `colorHex`, `sortOrder`, `createdAt`, the two relationships.

- [ ] **Step 6: Delete `StarredRegistry.swift`**

Run: `git rm Yana/Services/StarredRegistry.swift`

- [ ] **Step 7: Modify `TagFilterView.swift` — add the Starred row**

In `TagFilterListContent`, add a new toggle above the `Section("Tags")` block (bound to the new `AppSettings.starredOnly` from Task 3):

```swift
Section {
    Toggle(isOn: Binding(
        get: { settings.starredOnly },
        set: { settings.starredOnly = $0 }
    )) {
        Label { Text("Starred Only") } icon: { Image(systemName: "star.fill").foregroundStyle(.yellow) }
    }
}
```

Add the corresponding English/German entries to `Yana/Resources/Localizable.xcstrings` for `"Starred Only"` (`"Nur markierte"`, Apple-style infinitive-adjacent noun phrase — matches the existing terse label style used for other filter rows).

- [ ] **Step 8: Wire `starredOnly` into the predicate found in Step 1**

Add `&& (!settings.starredOnly || article.starred)` (or the equivalent boolean-array-filter form matching that predicate's actual style) at the exact file:line found in Step 1. Do not guess this blind — read that file's existing predicate composition first and match its style exactly.

- [ ] **Step 9: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStarredTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Yana/Models/Article.swift Yana/Models/Tag.swift Yana/Views/TagFilterView.swift YanaTests/ArticleStarredTests.swift project.yml
git rm Yana/Services/StarredRegistry.swift
git commit -m "Replace tag-based starring with a plain Article.starred boolean"
```

---

### Task 7: `Feed` model rework, delete `AggregatorType`/`AggregatorOptions`

**Files:**
- Modify: `Yana/Models/Feed.swift`
- Delete: `Yana/Aggregators/AggregatorType.swift`, `Yana/Models/AggregatorOptions.swift`
- Test: `YanaTests/FeedModelTests.swift`

**Interfaces:**
- Produces: `Feed.aggregator: String` (plain, unvalidated, replaces `aggregatorType`/`type: AggregatorType`), `Feed.logoImageHash: String?` (replaces `logoHash`), `Feed.tagIDs: [Int]` (replaces `tags: [Tag]?` snapshot — server article ids are `Int`, matching `/feeds`' wire shape; see Task 9 for how this is populated).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Feed model")
struct FeedModelTests {
    @Test func hasNoAggregatorTypeCoupling() throws {
        let container = try ModelContainer(for: Feed.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(name: "Test Feed", aggregator: "reddit", identifier: "1")
        context.insert(feed)
        #expect(feed.aggregator == "reddit")
        #expect(feed.logoImageHash == nil)
        #expect(feed.tagIDs.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedModelTests`
Expected: FAIL — `Feed.init(name:aggregator:identifier:)` doesn't exist yet.

- [ ] **Step 3: Rewrite `Feed.swift`**

```swift
import Foundation
import SwiftData

@Model
final class Feed {
    var name: String = ""
    /// Server's aggregator key (e.g. "reddit", "heise"), display-only. Nothing client-side
    /// branches on it any more -- there's no native feed creation/editing left to special-case,
    /// since feed management moved to the server's own web UI.
    var aggregator: String = ""
    var identifier: String = ""
    var dailyLimit: Int = 20
    var enabled: Bool = true
    var logoImageHash: String?
    var updatedAt: Date = Date.now

    /// Server-side tag ids this feed currently belongs to (`GET /api/v1/feeds`'s `tagIds`).
    /// A **live** join, refreshed on every `/feeds` fetch -- unlike the old per-article tag
    /// snapshot this replaces, tag membership here always reflects the feed's current state.
    var tagIDs: [Int] = []

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article]?

    init(name: String, aggregator: String, identifier: String, dailyLimit: Int = 20, enabled: Bool = true) {
        self.name = name
        self.aggregator = aggregator
        self.identifier = identifier
        self.dailyLimit = dailyLimit
        self.enabled = enabled
        self.updatedAt = .now
    }
}
```

- [ ] **Step 4: Delete `AggregatorType.swift` and `AggregatorOptions.swift`**

Run: `git rm Yana/Aggregators/AggregatorType.swift Yana/Models/AggregatorOptions.swift`

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedModelTests`
Expected: PASS. (Many other files will now fail to compile referencing the deleted `AggregatorType`/`AggregatorOptions`/old `Feed` properties — expected until Phase 4/7 delete those files too. Don't chase full-app green yet.)

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/Feed.swift YanaTests/FeedModelTests.swift
git rm Yana/Aggregators/AggregatorType.swift Yana/Models/AggregatorOptions.swift
git commit -m "Simplify Feed to a plain server mirror; delete AggregatorType/AggregatorOptions"
```

---

### Task 8: Delete `ArticleUID`, remove `ArticleSummary.uid`

**Files:**
- Delete: `Yana/Services/ArticleUID.swift`
- Modify: `Yana/Models/ArticleSummary.swift`

**Interfaces:**
- Produces: `ArticleSummary` unchanged except `uid` removed.

No test needed — this is a pure removal of a computed property confirmed (via `grep -rn "\.uid\b" Yana` returning zero hits outside `ArticleSummary.swift` itself) to have no consumer.

- [ ] **Step 1: Confirm no consumer exists (guard against having missed one)**

Run: `grep -rn "\.uid\b" Yana --include="*.swift" | grep -v ArticleSummary.swift`
Expected: no output. If this prints anything, stop and investigate before deleting — do not delete `ArticleUID` if something unexpected depends on it.

- [ ] **Step 2: Remove `uid` from `ArticleSummary.swift`**

Delete the computed property:
```swift
var uid: String {
    ArticleUID.make(feedIdentifier: feedIdentifier, aggregatorType: aggregatorType,
                     articleIdentifier: identifier, date: date, title: title)
}
```
Also remove `feedIdentifier`/`aggregatorType` fields and their `init(_ article:)`/`Codable` plumbing **only if** nothing else in `ArticleSummary` still needs them after Task 7's `Feed` rework — check with `grep -n "feedIdentifier\|aggregatorType" Yana/Models/ArticleSummary.swift` and delete each reference that existed solely to feed `uid`.

- [ ] **Step 3: Delete `ArticleUID.swift`**

Run: `git rm Yana/Services/ArticleUID.swift`

- [ ] **Step 4: Verify no build reference remains**

Run: `xcodegen generate && grep -rn "ArticleUID" Yana --include="*.swift"`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/ArticleSummary.swift
git rm Yana/Services/ArticleUID.swift
git commit -m "Delete ArticleUID and ArticleSummary.uid (dead since CloudKit removal, zero call sites)"
```

---

## Phase 4 — Sync engine

### Task 9: `SyncWriter` — the `@ModelActor` write path

**Files:**
- Create: `Yana/Services/SyncWriter.swift`
- Test: `YanaTests/SyncWriterTests.swift`

**Interfaces:**
- Consumes: `WireDocument` (Task 5), `Feed`/`Article`/`Tag` (Tasks 6–7).
- Produces:
```swift
struct SyncArticleSummaryWire: Decodable, Sendable {
    let id: Int; let feedId: Int; let name: String; let identifier: String
    let date: Date; let author: String; let icon: String?
    let read: Bool; let starred: Bool; let createdAt: Date; let updatedAt: Date
}
struct SyncFeedWire: Decodable, Sendable {
    let id: Int; let name: String; let aggregator: String; let identifier: String
    let enabled: Bool; let dailyLimit: Int; let tagIds: [Int]; let logoImageHash: String?
    let updatedAt: Date
}

@ModelActor
actor SyncWriter {
    func upsertSummaries(_ summaries: [SyncArticleSummaryWire]) -> [PersistentIdentifier]
    func applyContent(articleServerID: Int, document: WireDocument) -> Bool
    func applyRemovals(_ serverIDs: [Int])
    func replaceFeeds(_ feeds: [SyncFeedWire])
    func articlesMissingContent(limit: Int) -> [(persistentID: PersistentIdentifier, serverID: Int)]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SyncWriter")
struct SyncWriterTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    /// Server article ids need a durable local anchor to upsert against on later syncs.
    /// `Article` gains a `serverID: Int` for exactly this (added in Step 3 below alongside
    /// the rest of `SyncWriter`, since it's this task's own new column, not an earlier one).
    @Test func upsertInsertsNewArticlesAndTagsFeedRelationship() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let feedID = await writer.replaceFeeds([
            SyncFeedWire(id: 1, name: "Test Feed", aggregator: "feed_content", identifier: "f1",
                         enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
        ]).first

        let now = Date.now
        let ids = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                    date: now, author: "Jane", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        #expect(ids.count == 1)

        let context = container.mainContext
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.title == "Hello")
        #expect(articles.first?.serverID == 100)
        #expect(articles.first?.feed?.identifier == "f1")
        _ = feedID
    }

    @Test func upsertUpdatesExistingArticleByServerIDPreservingCreatedAt() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Original", identifier: "art-100",
                                    date: now, author: "Jane", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        let originalCreatedAt = try container.mainContext.fetch(FetchDescriptor<Article>()).first!.createdAt

        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Updated Title", identifier: "art-100",
                                    date: now, author: "Jane", icon: nil, read: false, starred: true,
                                    createdAt: now, updatedAt: now.addingTimeInterval(60))
        ])
        let updated = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
        #expect(updated.title == "Updated Title")
        #expect(updated.starred == true)
        #expect(updated.createdAt == originalCreatedAt)
    }

    @Test func applyRemovalsDeletesByServerID() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Gone Soon", identifier: "art-100",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        await writer.applyRemovals([100])
        let remaining = try container.mainContext.fetch(FetchDescriptor<Article>())
        #expect(remaining.isEmpty)
    }

    @Test func applyContentDecodesBlocksAndMarksHasContent() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Body Coming", identifier: "art-100",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        let doc = try JSONDecoder().decode(WireDocument.self, from: #"""
        {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"Body text","styles":[],"link":null}]}]}
        """#.data(using: .utf8)!)
        let applied = await writer.applyContent(articleServerID: 100, document: doc)
        #expect(applied)
        let article = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
        #expect(article.hasContent)
        #expect(article.blocks.count == 1)
    }

    @Test func articlesMissingContentReturnsOnlyUnfetchedOnes() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "A", identifier: "a", date: now,
                                    author: "", icon: nil, read: false, starred: false, createdAt: now, updatedAt: now),
            SyncArticleSummaryWire(id: 101, feedId: 1, name: "B", identifier: "b", date: now,
                                    author: "", icon: nil, read: false, starred: false, createdAt: now, updatedAt: now),
        ])
        let doc = try JSONDecoder().decode(WireDocument.self, from: #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
        _ = await writer.applyContent(articleServerID: 100, document: doc)

        let missing = await writer.articlesMissingContent(limit: 10)
        #expect(missing.count == 1)
        #expect(missing.first?.serverID == 101)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncWriterTests`
Expected: FAIL — `SyncWriter` doesn't exist, `Article.serverID` doesn't exist.

- [ ] **Step 3: Add `serverID` to `Article.swift`**

```swift
/// This article's id on the paired server -- the identity `SyncWriter` upserts/removes by.
/// `nil` only ever transiently (never persisted that way in practice, since every article now
/// originates from a sync response) -- kept optional rather than defaulted to `0` so a bug that
/// forgets to set it is a visible `nil`, not a silently-wrong `0` matching a real server id.
var serverID: Int?
```

Add `#Index<Article>([\.serverID])` alongside the existing `#Index` line for fast upsert lookups.

- [ ] **Step 4: Write `SyncWriter.swift`**

```swift
import Foundation
import SwiftData

struct SyncArticleSummaryWire: Decodable, Sendable {
    let id: Int
    let feedId: Int
    let name: String
    let identifier: String
    let date: Date
    let author: String
    let icon: String?
    let read: Bool
    let starred: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct SyncFeedWire: Decodable, Sendable {
    let id: Int
    let name: String
    let aggregator: String
    let identifier: String
    let enabled: Bool
    let dailyLimit: Int
    let tagIds: [Int]
    let logoImageHash: String?
    let updatedAt: Date
}

/// The `SyncEngine`'s write path. Mirrors `AggregationWriter`'s role exactly -- everything it
/// does is a plain `ModelContext` write, so `ArticleStore`'s `ModelContext.didSave` observer
/// picks up every change with no changes needed on that side (see `ArticleStore.swift`).
@ModelActor
actor SyncWriter {
    /// Upserts by `Article.serverID`. Preserves `createdAt` on update (matches the existing
    /// "an article's timeline position never jumps on re-fetch" rule). Returns the touched rows'
    /// `PersistentIdentifier`s so the caller can report progress without a second fetch.
    @discardableResult
    func upsertSummaries(_ summaries: [SyncArticleSummaryWire]) -> [PersistentIdentifier] {
        var touched: [PersistentIdentifier] = []
        for summary in summaries {
            let existingDescriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == summary.id })
            let feedDescriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.identifier == summary.feedId.description })
            // Feeds are looked up by their own serverID equivalent -- see `replaceFeeds` below,
            // which stores the server feed id into `Feed.identifier` verbatim (feeds have no
            // separate natural identifier client-side any more; the server's id *is* the identity).
            let feed = try? modelContext.fetch(feedDescriptor).first

            if let article = try? modelContext.fetch(existingDescriptor).first {
                article.title = summary.name
                article.author = summary.author
                article.starred = summary.starred
                article.feed = feed
                touched.append(article.persistentModelID)
            } else {
                let article = Article(
                    title: summary.name, identifier: summary.identifier, url: "",
                    date: summary.date, author: summary.author, iconURL: summary.icon
                )
                article.serverID = summary.id
                article.starred = summary.starred
                article.createdAt = summary.createdAt
                article.feed = feed
                modelContext.insert(article)
                touched.append(article.persistentModelID)
            }
        }
        try? modelContext.save()
        return touched
    }

    /// Decodes `document` into `[Block]` and writes it to the matching article, marking
    /// `hasContent`. Returns `false` (no throw) if no local article with this `serverID` exists
    /// yet -- a race between a summary upsert and its content fetch landing out of order is a
    /// normal, expected condition in a bounded-concurrency pipeline, not an error.
    @discardableResult
    func applyContent(articleServerID: Int, document: WireDocument) -> Bool {
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == articleServerID })
        guard let article = try? modelContext.fetch(descriptor).first else { return false }
        article.blocks = document.blocks
        article.hasContent = true
        try? modelContext.save()
        return true
    }

    func applyRemovals(_ serverIDs: [Int]) {
        guard !serverIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { serverIDs.contains($0.serverID ?? -1) })
        guard let toDelete = try? modelContext.fetch(descriptor) else { return }
        for article in toDelete { modelContext.delete(article) }
        try? modelContext.save()
    }

    /// Full replace-by-upsert of every feed the server returned (the `/feeds` response is small
    /// and unpaginated, so there's no incremental-delta protocol to speak of here -- unlike
    /// articles). Stores the server's feed id as `Feed.identifier` (string form), since feeds
    /// have no other natural identity worth keeping client-side any more.
    @discardableResult
    func replaceFeeds(_ feeds: [SyncFeedWire]) -> [PersistentIdentifier] {
        var touched: [PersistentIdentifier] = []
        for wire in feeds {
            let idString = String(wire.id)
            let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.identifier == idString })
            if let feed = try? modelContext.fetch(descriptor).first {
                feed.name = wire.name
                feed.aggregator = wire.aggregator
                feed.enabled = wire.enabled
                feed.dailyLimit = wire.dailyLimit
                feed.tagIDs = wire.tagIds
                feed.logoImageHash = wire.logoImageHash
                feed.updatedAt = wire.updatedAt
                touched.append(feed.persistentModelID)
            } else {
                let feed = Feed(name: wire.name, aggregator: wire.aggregator, identifier: idString,
                                 dailyLimit: wire.dailyLimit, enabled: wire.enabled)
                feed.tagIDs = wire.tagIds
                feed.logoImageHash = wire.logoImageHash
                feed.updatedAt = wire.updatedAt
                modelContext.insert(feed)
                touched.append(feed.persistentModelID)
            }
        }
        try? modelContext.save()
        return touched
    }

    /// The content-backfill candidate list: every locally-known article whose body hasn't
    /// synced yet, oldest-`createdAt`-first, capped at `limit` so one pass never tries to fetch
    /// an unbounded backlog.
    func articlesMissingContent(limit: Int) -> [(persistentID: PersistentIdentifier, serverID: Int)] {
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.hasContent == false && $0.serverID != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = limit
        guard let articles = try? modelContext.fetch(descriptor) else { return [] }
        return articles.compactMap { article in
            guard let serverID = article.serverID else { return nil }
            return (article.persistentModelID, serverID)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncWriterTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/SyncWriter.swift Yana/Models/Article.swift YanaTests/SyncWriterTests.swift project.yml
git commit -m "Add SyncWriter: the @ModelActor write path for server-sourced sync"
```

---

### Task 10: `SyncEngine` — orchestrator with pagination, bounded-concurrency backfill

**Files:**
- Create: `Yana/Services/SyncEngine.swift`
- Test: `YanaTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `YanaAPIClient` (Task 1), `SyncWriter` (Task 9), `AppSettings.syncCursor` (Task 3), `OffMainActor.run` (existing).
- Produces:
```swift
struct SyncResult: Sendable, Equatable { let newCount: Int; let updatedCount: Int; let removedCount: Int }

@MainActor
final class SyncEngine {
    init(container: ModelContainer, client: YanaAPIClient, settings: AppSettings = AppSettings())
    func sync() async throws -> SyncResult
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SyncEngine")
struct SyncEngineTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func stubClient(responses: [String: (Data, Int)]) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let path = request.url!.path
            let (data, status) = responses[path] ?? (#"{"error":{"code":"not_found","message":"unhandled path in test"}}"#.data(using: .utf8)!, 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func syncInsertsNewArticlesAndFetchesTheirContent() async throws {
        let container = try makeContainer()
        let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)

        let syncResponse = #"""
        {"new":[{"id":100,"feedId":1,"name":"Hello","identifier":"a1","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"updated":[],"removed":[],"nextCursor":"cursor-1"}
        """#.data(using: .utf8)!
        let contentResponse = #"{"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"Body","styles":[],"link":null}]}]}"#.data(using: .utf8)!
        let feedsResponse = #"{"feeds":[{"id":1,"name":"Test Feed","aggregator":"feed_content","identifier":"1","enabled":true,"dailyLimit":20,"tagIds":[],"logoImageHash":null,"updatedAt":"2026-01-01T00:00:00Z"}]}"#.data(using: .utf8)!

        let client = stubClient(responses: [
            "/api/v1/articles/sync": (syncResponse, 200),
            "/api/v1/articles/100/content": (contentResponse, 200),
            "/api/v1/feeds": (feedsResponse, 200),
        ])

        let engine = SyncEngine(container: container, client: client, settings: settings)
        let result = try await engine.sync()

        #expect(result.newCount == 1)
        let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.hasContent == true)
        #expect(settings.syncCursor == "cursor-1")
    }

    @Test func resyncRequiredClearsTheCursorAndRetries() async throws {
        let container = try makeContainer()
        let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.syncCursor = "stale-cursor"

        var callCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            if request.url!.path == "/api/v1/feeds" {
                return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
            }
            callCount += 1
            if callCount == 1 {
                return (response, #"{"resyncRequired":true}"#.data(using: .utf8)!)
            }
            return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":"fresh-cursor"}"#.data(using: .utf8)!)
        }
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

        let engine = SyncEngine(container: container, client: client, settings: settings)
        _ = try await engine.sync()

        #expect(settings.syncCursor == "fresh-cursor")
        #expect(callCount == 2)
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let stub = Self.stub else { return }
        let (response, data) = stub(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

Note: `MockURLProtocol` is defined in Task 1's test file too — since both are in the `YanaTests` target, delete the duplicate definition from whichever file is added second (keep one shared copy; simplest is to move it into a new `YanaTests/Support/MockURLProtocol.swift` and delete it from both test files, updating both to reference the shared one). Do this as part of this task's Step 1, not as a separate cleanup task.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncEngineTests`
Expected: FAIL — `SyncEngine`/`SyncResult` don't exist.

- [ ] **Step 3: Write `SyncEngine.swift`**

```swift
import Foundation
import SwiftData

struct SyncResult: Sendable, Equatable {
    let newCount: Int
    let updatedCount: Int
    let removedCount: Int
}

private struct SyncPage: Decodable {
    let new: [SyncArticleSummaryWire]?
    let updated: [SyncArticleSummaryWire]?
    let removed: [Int]?
    let nextCursor: String?
    let resyncRequired: Bool?
}

private struct FeedsResponse: Decodable { let feeds: [SyncFeedWire] }

/// Offline-first sync: a full pass replicates the server's article set -- summaries, full block
/// content, and every referenced image -- into the local SwiftData mirror, not just metadata.
/// Content/image fetches are eager, not lazy-on-render; see the design spec's "Local persistence"
/// decision for why (full-text search and true offline reading both depend on it).
@MainActor
final class SyncEngine {
    private let container: ModelContainer
    private let client: YanaAPIClient
    private let settings: AppSettings
    private let maxConcurrentContentFetches = 6

    init(container: ModelContainer, client: YanaAPIClient, settings: AppSettings = AppSettings()) {
        self.container = container
        self.client = client
        self.settings = settings
    }

    @discardableResult
    func sync() async throws -> SyncResult {
        var totalNew = 0, totalUpdated = 0, totalRemoved = 0

        try await syncFeeds()

        while true {
            let page: SyncPage = try await client.get(
                "/api/v1/articles/sync",
                query: settings.syncCursor.map { ["cursor": $0, "limit": "200"] } ?? ["limit": "200"]
            )

            if page.resyncRequired == true {
                settings.syncCursor = nil
                continue
            }

            let newSummaries = page.new ?? []
            let updatedSummaries = page.updated ?? []
            let removed = page.removed ?? []

            let writer = SyncWriter(modelContainer: container)
            _ = await OffMainActor.run { await writer.upsertSummaries(newSummaries) }
            _ = await OffMainActor.run { await writer.upsertSummaries(updatedSummaries) }
            await OffMainActor.run { await writer.applyRemovals(removed) }

            totalNew += newSummaries.count
            totalUpdated += updatedSummaries.count
            totalRemoved += removed.count

            settings.syncCursor = page.nextCursor

            // A page with fewer than the full limit means we've caught up to head.
            let fullPage = (newSummaries.count + updatedSummaries.count) >= 200
            if !fullPage { break }
        }

        try await backfillMissingContent()

        return SyncResult(newCount: totalNew, updatedCount: totalUpdated, removedCount: totalRemoved)
    }

    private func syncFeeds() async throws {
        let response: FeedsResponse = try await client.get("/api/v1/feeds")
        let writer = SyncWriter(modelContainer: container)
        _ = await OffMainActor.run { await writer.replaceFeeds(response.feeds) }
    }

    /// Fetches full content for every locally-known article that doesn't have it yet, at
    /// bounded concurrency. A dropped connection here doesn't lose progress -- the cursor has
    /// already advanced past these articles' summaries, so this backfill (driven by
    /// `hasContent == false`, not by re-listing from `/articles/sync`) is what retries them on
    /// the next sync pass. Deliberately swallows individual fetch failures rather than aborting
    /// the whole pass -- a spotty connection should degrade to "some articles still pending,"
    /// not "sync failed."
    private func backfillMissingContent() async throws {
        let writer = SyncWriter(modelContainer: container)
        let pending = await OffMainActor.run { await writer.articlesMissingContent(limit: 500) }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0

            func launchNext() {
                guard let item = iterator.next() else { return }
                inFlight += 1
                group.addTask { [client, container] in
                    do {
                        let document: WireDocument = try await client.get("/api/v1/articles/\(item.serverID)/content")
                        let writer = SyncWriter(modelContainer: container)
                        _ = await writer.applyContent(articleServerID: item.serverID, document: document)
                    } catch {
                        // Leave hasContent == false; picked up again on the next sync pass.
                    }
                }
            }

            for _ in 0..<maxConcurrentContentFetches { launchNext() }
            while await group.next() != nil {
                inFlight -= 1
                launchNext()
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncEngineTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/SyncEngine.swift YanaTests/SyncEngineTests.swift YanaTests/Support/MockURLProtocol.swift project.yml
git commit -m "Add SyncEngine: offline-first sync orchestrator with content/image backfill"
```

---

### Task 11: Rework `ImageStore` to fetch-by-hash; delete the CloudKit image bridge

**Files:**
- Move + modify: `Yana/Aggregators/Utils/ImageStore.swift` → `Yana/Services/ImageStore.swift`
- Move: `Yana/Aggregators/Utils/ArticleHeaderLogo.swift` → `Yana/Services/ArticleHeaderLogo.swift`
- Move: `Yana/Aggregators/Utils/ReaderWeb.swift` → `Yana/Reader/ReaderWeb.swift`
- Delete: `Yana/Services/ImageSync.swift`, `Yana/Aggregators/Utils/ImageCompressor.swift`, `Yana/Aggregators/Utils/LogoBackgroundRemover.swift`, `Yana/Aggregators/FeedLogoResolver.swift`
- Delete: `Yana/Models/StoredImage.swift` (SwiftData model — grep to confirm its file name/location first: `grep -rln "class StoredImage" Yana`)
- Modify: `Yana/Views/Config/FeedLogoView.swift`, `Yana/Reader/ReaderImageCache.swift`
- Modify: `Yana/YanaApp.swift` (remove `StoredImage.self` from `AppContainer.shared`'s model list)
- Test: `YanaTests/ImageStoreTests.swift`

**Interfaces:**
- Produces: `ImageStore.fetchIfNeeded(hash: String, client: YanaAPIClient) async -> Bool` (replaces `store(remoteURL:isHeader:removeWhiteBackground:)`), keeps `fileURL(forHash:)`/`fileExists(forHash:)`/`storeData(_:ext:)` (still used by DEBUG fixtures) unchanged in signature.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("ImageStore fetch-by-hash")
struct ImageStoreTests {
    private func stubClient(bytes: Data, contentType: String) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
            return (response, bytes)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func fetchesAndCachesOnMiss() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ImageStore(directory: tempDir)
        let client = stubClient(bytes: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")

        let fetched = await store.fetchIfNeeded(hash: "abc123", client: client)
        #expect(fetched)
        #expect(await store.fileExists(forHash: "abc123"))
    }

    @Test func doesNotRefetchWhenAlreadyOnDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ImageStore(directory: tempDir)
        _ = store.storeData(Data([0x01]), ext: "jpg")
        let hash = ImageStore.hashForTesting(Data([0x01]))

        var requestCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data())
        }
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

        let fetched = await store.fetchIfNeeded(hash: hash, client: client)
        #expect(fetched)
        #expect(requestCount == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageStoreTests`
Expected: FAIL — `ImageStore.fetchIfNeeded`/`hashForTesting` don't exist; `ImageStore(directory:)`'s current `init` requires a `fetch` closure param this test doesn't pass in that form.

- [ ] **Step 3: Move and rewrite `ImageStore.swift`**

Run: `git mv Yana/Aggregators/Utils/ImageStore.swift Yana/Services/ImageStore.swift`

Replace `store(remoteURL:isHeader:removeWhiteBackground:)` and the `fetch` closure/`HTTPClient` dependency with:

```swift
actor ImageStore {
    private let directory: URL
    private var extensions: [String: String] = [:]

    /// The response cap and accept header carried over from the old on-device-scraping
    /// `HTTPClient` -- raised specifically for large Reddit GIFs. The server doesn't enforce an
    /// equivalent cap itself, so this stays a client-side protection.
    static let maxImageResponseBytes = 64 * 1024 * 1024
    static let imageAccept = "image/*,*/*;q=0.8"

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                let stem = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension
                if !stem.isEmpty, !ext.isEmpty { extensions[stem] = ext }
            }
        }
    }

    static let shared: ImageStore = {
        let dir = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("images") ?? FileManager.default.temporaryDirectory.appendingPathComponent("images")
        return ImageStore(directory: dir)
    }()

    /// Fetches `GET /images/:hash` on cache miss and writes the raw bytes verbatim under that
    /// exact hash -- no recompression, no re-hashing (the server already stores final processed
    /// bytes for both article images and feed logos; the hash is the server's own identity, not
    /// locally computed as it was before). Returns whether bytes are on disk afterward.
    func fetchIfNeeded(hash: String, client: YanaAPIClient) async -> Bool {
        if fileExists(forHash: hash) { return true }
        guard let (data, response) = try? await client.getRaw("/api/v1/images/\(hash)"), data.count <= Self.maxImageResponseBytes else {
            return false
        }
        let ext = Self.fileExtension(forContentType: response.value(forHTTPHeaderField: "Content-Type"))
        extensions[hash] = ext
        let url = fileURL(forHash: hash)
        try? data.write(to: url)
        return true
    }

    func storeData(_ data: Data, ext: String) -> String {
        let hash = Self.hash(data)
        extensions[hash] = ext
        let url = fileURL(forHash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return hash
    }

    func fileURL(forHash hash: String) -> URL {
        directory.appendingPathComponent(hash).appendingPathExtension(extensions[hash] ?? "img")
    }

    func fileExists(forHash hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forHash: hash).path)
    }

    func rawData(forHash hash: String) -> Data? {
        try? Data(contentsOf: fileURL(forHash: hash))
    }

    func recordedExt(forHash hash: String) -> String { extensions[hash] ?? "img" }

    func allHashes() -> Set<String> { Set(extensions.keys) }

    func remove(forHash hash: String) {
        try? FileManager.default.removeItem(at: fileURL(forHash: hash))
        extensions.removeValue(forKey: hash)
    }

    private static func fileExtension(forContentType contentType: String?) -> String {
        switch contentType?.split(separator: ";").first.map(String.init) {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "img"
        }
    }

    private static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    nonisolated static func hashForTesting(_ data: Data) -> String { hash(data) }
    #endif
}
```

Keep `import CryptoKit` at the top; delete the `SwiftSoup`-based `rewriteImages(in:store:baseURL:)`/`largestSrcsetURL` functions at the bottom of the old file — those rewrote scraped HTML's `<img>` tags, which no longer happens client-side (the server already delivers `yana-img://` refs directly in its `WireBlock.image`).

- [ ] **Step 4: Move `ArticleHeaderLogo.swift` and `ReaderWeb.swift` (no content change)**

Run:
```bash
git mv Yana/Aggregators/Utils/ArticleHeaderLogo.swift Yana/Services/ArticleHeaderLogo.swift
git mv Yana/Aggregators/Utils/ReaderWeb.swift Yana/Reader/ReaderWeb.swift
```

- [ ] **Step 5: Delete the CloudKit image bridge and dead recompression code**

```bash
git rm Yana/Services/ImageSync.swift
git rm Yana/Aggregators/Utils/ImageCompressor.swift
git rm Yana/Aggregators/Utils/LogoBackgroundRemover.swift
git rm Yana/Aggregators/FeedLogoResolver.swift
```

Find and delete the `StoredImage` model file: run `grep -rln "class StoredImage" Yana`, then `git rm` that path. Remove `StoredImage.self` from `AppContainer.shared`'s `ModelContainer(for: Feed.self, Tag.self, Article.self, StoredImage.self)` call in `Yana/YanaApp.swift`, leaving `Feed.self, Tag.self, Article.self`.

- [ ] **Step 6: Update `FeedLogoView.swift` and `ReaderImageCache.swift`'s materialize calls**

In `Yana/Views/Config/FeedLogoView.swift`, replace:
```swift
_ = await ImageSync.materialize(hash: hash, context: AppContainer.shared.mainContext, imageStore: store)
```
with a call to the new fetch-by-hash, requiring a `YanaAPIClient` — thread one in via a new parameter (this view needs a client reference; add a simple `@Environment`-injected client or a `.shared`-style singleton client holder introduced in Task 12 when the app wires auth end-to-end). For now, to keep this task self-contained and compiling in isolation, change the signature to accept a client explicitly:
```swift
@MainActor
static func image(forHash hash: String?, client: YanaAPIClient, in store: ImageStore = .shared) async -> UIImage? {
    guard let hash else { return nil }
    _ = await store.fetchIfNeeded(hash: hash, client: client)
    let url = await store.fileURL(forHash: hash)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
}
```
and update `FeedLogoView`'s `.task(id: hash)` to pass a client (Task 12 finalizes where that client instance actually comes from app-wide — leave a `// TODO(Task 12): source from the app's authenticated client` comment here rather than inventing a wrong answer now).

Apply the same change to `Yana/Reader/ReaderImageCache.swift`'s `load(_:)` — replace its `ImageSync.materialize(...)` call with `ImageStore.shared.fetchIfNeeded(hash:client:)`, threading a client the same way.

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageStoreTests`
Expected: PASS (2 tests). Full-app build is still not expected to be green (Task 12 finishes wiring the client through).

- [ ] **Step 8: Commit**

```bash
git add -A Yana/Services/ImageStore.swift Yana/Services/ArticleHeaderLogo.swift Yana/Reader/ReaderWeb.swift Yana/Views/Config/FeedLogoView.swift Yana/Reader/ReaderImageCache.swift Yana/YanaApp.swift YanaTests/ImageStoreTests.swift project.yml
git commit -m "Rework ImageStore to fetch-by-hash; delete the CloudKit-era StoredImage bridge"
```

---

### Task 12: Wire `SyncEngine` end-to-end; delete on-device aggregation

**Files:**
- Create: `Yana/Services/AuthenticatedClient.swift` (small app-wide holder resolving the current `YanaAPIClient` from `AppSettings.serverBaseURL` + `KeychainService.loadDeviceToken()`)
- Modify: `Yana/YanaApp.swift`, `Yana/ContentView.swift`, `Yana/Views/Config/FeedLogoView.swift`, `Yana/Reader/ReaderImageCache.swift` (resolve the `// TODO(Task 12)` from Task 11)
- Delete: `Yana/Services/AggregationService.swift`, `AggregationWriter.swift`
- Delete: `Yana/Aggregators/AggregatedArticle.swift`, `AggregationLogic.swift`, `Aggregator.swift`, `AggregatorRegistry.swift`, `ArticleUpsert.swift`, `FeedConfig.swift`, `RetentionCleanup.swift`
- Delete: `Yana/Aggregators/Concrete/` (entire directory)
- Delete: `Yana/Aggregators/Utils/BlockParser.swift`, `BlueskyEmbed.swift`, `ContentFormatter.swift`, `DomainImageOverrides.swift`, `EmbedRewriter.swift`, `FaviconResolver.swift`, `FeedDiscovery.swift`, `FeedParser.swift`, `FeedURLResolver.swift`, `HTMLUtils.swift`, `HeaderElementExtractor.swift`, `HTTPClient.swift`
- Delete: `Yana/Services/ImagePrune.swift` (+ its candidate-store file — `grep -rln "ImagePruneCandidateStore" Yana` to find it), `LibraryDedup.swift`
- Move: `Yana/Aggregators/ArticleSearch.swift` → `Yana/Services/ArticleSearch.swift`
- Delete the (now-empty) `Yana/Aggregators/` directory.
- Fix: `Yana/Utilities/ScreenshotSeed.swift` (discovered during Task 7's execution: constructs `Feed`/`Article` directly with the old pre-Task-7 shape — `Feed(name:aggregatorType:...)`, `feed.logoHash =`, `feed.tags =`/`article.tags =` — and has been broken since Task 7 landed; nothing in this plan owns fixing it otherwise, and it's needed for `fastlane screenshots` to run again). Get it compiling with **mechanical** adaptation only, matching the pattern Task 7 already used for `YanaTests/LibraryFixture.swift`: update the `Feed(...)` construction to the new `init(name:aggregator:identifier:...)`, rename `logoHash` → `logoImageHash`, and replace any `feed.tags =`/`article.tags =` assignment with whatever `Feed.tagIDs`/`Article.starred` now actually needs (a fixture doesn't need real server tag ids — dropping tag assignment entirely, or assigning a placeholder `tagIDs`, is fine; do not attempt to redesign the fixture's tag/starred *behavior*, only make it compile against the new shapes). A full review of what the screenshot fixtures should show post-rework (e.g. the `05_AI` shot's caption referencing the deleted bring-your-own-key AI section) is tracked separately in the design spec's "Out of scope / follow-ups" — this step is scoped to "compiles and runs," not "still produces meaningful screenshots."
- Modify: `Yana/Services/ArticleStore.swift` (remove the inert `.NSPersistentStoreRemoteChange` observer)
- Test: `YanaTests/AuthenticatedClientTests.swift`

**Interfaces:**
- Produces: `@MainActor final class AuthenticatedClient { static func current(settings: AppSettings = AppSettings()) -> YanaAPIClient? }`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AuthenticatedClient")
struct AuthenticatedClientTests {
    @Test func returnsNilWithoutAServerURLOrToken() {
        let defaults = UserDefaults(suiteName: "AuthenticatedClientTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        KeychainService.deleteDeviceToken()
        #expect(AuthenticatedClient.current(settings: settings) == nil)
    }

    @Test func buildsAClientWhenBothArePresent() {
        let defaults = UserDefaults(suiteName: "AuthenticatedClientTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.serverBaseURL = "https://yana.example.com"
        KeychainService.saveDeviceToken("test-token")
        defer { KeychainService.deleteDeviceToken() }

        let client = AuthenticatedClient.current(settings: settings)
        #expect(client?.baseURL == URL(string: "https://yana.example.com"))
        #expect(client?.token == "test-token")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AuthenticatedClientTests`
Expected: FAIL — `AuthenticatedClient` doesn't exist.

- [ ] **Step 3: Write `AuthenticatedClient.swift`**

```swift
import Foundation

/// Resolves the app's current `YanaAPIClient` from persisted settings + Keychain. `nil` means
/// "not paired yet" -- callers (SyncEngine's app-lifecycle trigger, the image-fetch call sites)
/// treat that as "nothing to do," not an error.
@MainActor
enum AuthenticatedClient {
    static func current(settings: AppSettings = AppSettings()) -> YanaAPIClient? {
        guard !settings.serverBaseURL.isEmpty,
              let baseURL = URL(string: settings.serverBaseURL),
              let token = KeychainService.loadDeviceToken()
        else {
            return nil
        }
        return YanaAPIClient(baseURL: baseURL, token: token)
    }
}
```

- [ ] **Step 4: Resolve Task 11's `// TODO(Task 12)` call sites**

In `Yana/Views/Config/FeedLogoView.swift`'s `.task(id: hash)`:
```swift
.task(id: hash) {
    guard let client = AuthenticatedClient.current() else { return }
    image = await FeedLogo.image(forHash: hash, client: client)
}
```
Apply the same pattern in `Yana/Reader/ReaderImageCache.swift`'s `load(_:)` (guard-return early with no image if `AuthenticatedClient.current()` is `nil`, instead of throwing).

- [ ] **Step 5: Delete on-device aggregation wholesale**

```bash
git rm Yana/Services/AggregationService.swift Yana/Services/AggregationWriter.swift
git rm Yana/Aggregators/AggregatedArticle.swift Yana/Aggregators/AggregationLogic.swift Yana/Aggregators/Aggregator.swift Yana/Aggregators/AggregatorRegistry.swift Yana/Aggregators/ArticleUpsert.swift Yana/Aggregators/FeedConfig.swift Yana/Aggregators/RetentionCleanup.swift
git rm -r Yana/Aggregators/Concrete
git rm Yana/Aggregators/Utils/BlockParser.swift Yana/Aggregators/Utils/BlueskyEmbed.swift Yana/Aggregators/Utils/ContentFormatter.swift Yana/Aggregators/Utils/DomainImageOverrides.swift Yana/Aggregators/Utils/EmbedRewriter.swift Yana/Aggregators/Utils/FaviconResolver.swift Yana/Aggregators/Utils/FeedDiscovery.swift Yana/Aggregators/Utils/FeedParser.swift Yana/Aggregators/Utils/FeedURLResolver.swift Yana/Aggregators/Utils/HTMLUtils.swift Yana/Aggregators/Utils/HeaderElementExtractor.swift Yana/Aggregators/Utils/HTTPClient.swift
git rm Yana/Services/LibraryDedup.swift
```

Find and remove `ImagePrune.swift` and its candidate-quarantine store file:
```bash
grep -rln "ImagePruneCandidateStore\|struct ImagePrunePlan\|final class ImagePruneRunner" Yana
```
`git rm` every file that search turns up.

Move the search matcher out before the directory disappears:
```bash
git mv Yana/Aggregators/ArticleSearch.swift Yana/Services/ArticleSearch.swift
```

Confirm `Yana/Aggregators/` is now empty and remove it:
```bash
find Yana/Aggregators -type f
# expect no output
rmdir Yana/Aggregators/Concrete Yana/Aggregators/Utils Yana/Aggregators 2>/dev/null || true
```

- [ ] **Step 6: Remove the inert CloudKit remote-change observer from `ArticleStore.swift`**

Delete the `NotificationCenter... forName: .NSPersistentStoreRemoteChange` observer registration and its `enqueueCountProbe()`/`reconcileIfCountDiffers()` machinery **only if** nothing else in this file depends on it for a non-CloudKit reason — read the surrounding code first (`start()`, the `isolated deinit`) and remove exactly the CloudKit-specific observer + its now-unreachable helper methods, leaving the `ModelContext.didSave` observer and splice/full-reload machinery completely untouched (that's what `SyncWriter`'s saves rely on).

- [ ] **Step 7: Wire `SyncEngine` into app lifecycle**

In `Yana/YanaApp.swift`'s main `WindowGroup`, replace whatever `.task`/`scenePhase`-triggered call currently exists for aggregation (there was none wired directly here before — aggregation was onboarding-Finish- and `BackgroundRefreshManager`-triggered only; leave `BackgroundRefreshManager`'s rewiring to Task 14) with a foreground sync trigger:
```swift
.task {
    guard let client = AuthenticatedClient.current() else { return }
    _ = try? await SyncEngine(container: AppContainer.shared, client: client).sync()
}
```
placed alongside the existing `articleStore.start()`/`BlockMigration.run` calls in that same `.task`.

- [ ] **Step 8: Run the full test suite and fix any remaining compile errors**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`

This is the first point in the plan where a fully clean build is realistic for everything touched so far — `WelcomeView`, `FeedsView`/`TagsView`/`FeedEditorView`, and the Settings sections referencing deleted AI/Reddit/YouTube code are **not yet fixed** (Tasks 15–22) and will still fail to compile; if the build error output is dominated by those known-pending files, that's expected — don't fix them here, they have their own tasks. Fix anything **outside** that known set (e.g. a stray reference to a just-deleted `AggregatorType` you find in a file not on this plan's radar) before moving on, and note it inline in the commit message.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Wire SyncEngine end-to-end; delete on-device aggregation entirely

Yana/Aggregators/ is gone -- ArticleSearch relocated to Services/,
everything else (scrapers, BlockParser, HTTPClient, upsert/retention
logic) deleted as redundant with server-side work. AggregationService/
AggregationWriter/LibraryDedup/ImagePrune follow for the same reason."
```

---

## Phase 5 — Actions & background refresh

### Task 13: Article actions (star, reload, update-all) via the API

**Files:**
- Create: `Yana/Services/ArticleActions.swift`
- Modify: call sites that currently invoke `AggregationService.update(article:)`/`forceReload(article:)`/`updateAll()` for star/reload/update — locate with `grep -rn "AggregationService(" Yana --include="*.swift"` (expected to be empty after Task 12's deletion; this grep instead finds any view still calling the now-deleted type, which must be these exact call sites)
- Test: `YanaTests/ArticleActionsTests.swift`

**Interfaces:**
- Produces:
```swift
@MainActor
final class ArticleActions {
    init(client: YanaAPIClient)
    func setStarred(_ starred: Bool, articleServerID: Int) async throws
    func reload(articleServerID: Int) async throws
    func updateAll() async throws -> Int   // returns runId's job count once known, or 0 immediately (see Step 3)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleActions")
struct ArticleActionsTests {
    private func stubClient(pathsToResponses: [String: (Data, Int)]) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let (data, status) = pathsToResponses[key] ?? (Data(), 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func setStarredSendsAPatchWithTheBooleanBody() async throws {
        let client = stubClient(pathsToResponses: [
            "PATCH /api/v1/articles/100": (#"{"id":100,"starred":true}"#.data(using: .utf8)!, 200)
        ])
        let actions = ArticleActions(client: client)
        try await actions.setStarred(true, articleServerID: 100)
    }

    @Test func reloadPostsAndSucceedsOn202() async throws {
        let client = stubClient(pathsToResponses: [
            "POST /api/v1/articles/100/reload": (#"{"jobId":1}"#.data(using: .utf8)!, 202)
        ])
        let actions = ArticleActions(client: client)
        try await actions.reload(articleServerID: 100)
    }

    @Test func updateAllPostsToAggregate() async throws {
        let client = stubClient(pathsToResponses: [
            "POST /api/v1/aggregate": (#"{"runId":5}"#.data(using: .utf8)!, 202)
        ])
        let actions = ArticleActions(client: client)
        let runID = try await actions.updateAll()
        #expect(runID == 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleActionsTests`
Expected: FAIL — `ArticleActions` doesn't exist.

- [ ] **Step 3: Write `ArticleActions.swift`**

```swift
import Foundation

private struct StarredBody: Encodable { let starred: Bool }
private struct StarredResponse: Decodable { let id: Int; let starred: Bool }
private struct ReloadResponse: Decodable { let jobId: Int }
private struct AggregateResponse: Decodable { let runId: Int }

/// Thin façade over the article-mutating parts of the API, so UI code doesn't construct
/// `YanaAPIClient` calls inline. Read paths (sync, content, feeds) live in `SyncEngine` instead --
/// this is specifically the user-initiated write/trigger surface.
@MainActor
final class ArticleActions {
    private let client: YanaAPIClient

    init(client: YanaAPIClient) {
        self.client = client
    }

    func setStarred(_ starred: Bool, articleServerID: Int) async throws {
        let _: StarredResponse = try await client.patch("/api/v1/articles/\(articleServerID)", body: StarredBody(starred: starred))
    }

    func reload(articleServerID: Int) async throws {
        let _: ReloadResponse = try await client.post("/api/v1/articles/\(articleServerID)/reload")
    }

    @discardableResult
    func updateAll() async throws -> Int {
        let response: AggregateResponse = try await client.post("/api/v1/aggregate")
        return response.runId
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleActionsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire star/reload/update-all UI call sites**

Run `grep -rn "AggregationService(" Yana --include="*.swift"` and `grep -rn "\.setStarred\|forceReload(article" Yana --include="*.swift"` to find every remaining reader/`ArticleListView` call site (the reader's star-toggle button, the reader overflow menu's "Reload," `ArticleListView`'s swipe "Reload," the reader's pull-to-refresh "Update"). For each: replace the call with the corresponding `ArticleActions` method, guarding on `AuthenticatedClient.current()` being non-nil, and using `article.serverID` (already present per Task 9) instead of the deleted `PersistentIdentifier`-keyed `AggregationService` methods. After a successful `setStarred`/`reload`, update `article.starred`/call `SyncEngine.sync()` (for reload, since the reloaded content needs re-fetching) rather than assuming the local model already reflects the change — a `PATCH`/`POST` response doesn't itself deliver new content, only an ack.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/ArticleActions.swift YanaTests/ArticleActionsTests.swift project.yml
git add -u
git commit -m "Add ArticleActions; wire star/reload/update-all to the API"
```

---

### Task 14: `BackgroundRefreshManager` calls `SyncEngine`

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift`
- Test: existing background-refresh tests, if any (`grep -rln "BackgroundRefreshManager" YanaTests`) — update in place rather than creating a new file if one exists.

**Interfaces:**
- Consumes: `SyncEngine.sync() -> SyncResult` (Task 10), `AuthenticatedClient.current()` (Task 12).
- Modifies: `BackgroundRefreshManager.runRefresh(...)`'s signature from taking an `AggregationService` to taking a `SyncEngine`.

- [ ] **Step 1: Locate and read the existing test file fully**

Run: `grep -rln "BackgroundRefreshManager" YanaTests`

Read whatever that finds in full before editing — match its existing dependency-injection style (the class already takes injectable `container`/`secondsProvider`/`now`/`onScheduleAttempt`; `runRefresh` takes injectable `service`/`notifier`/`settings`).

- [ ] **Step 2: Update the failing assertions in that file to expect `SyncEngine`, not `AggregationService`**

Change every constructed `AggregationService(...)` fixture to a `SyncEngine(container:client:settings:)` built against a stubbed `YanaAPIClient` (same `MockURLProtocol` pattern used throughout this plan), and update `runRefresh`'s call signature in the assertions to match Step 3's new signature.

- [ ] **Step 3: Modify `runRefresh` and its three call sites**

```swift
@MainActor
static func runRefresh(
    engine: SyncEngine,
    notifier: Notifying = NotificationService(),
    settings: AppSettings = AppSettings()
) async {
    guard let result = try? await engine.sync() else { return }
    let inserted = result.newCount
    guard settings.notificationsEnabled, inserted > 0 else { return }
    let authorized = await notifier.isAuthorized()
    guard NewArticleNotification.shouldNotify(
        enabled: settings.notificationsEnabled,
        authorized: authorized,
        insertedCount: inserted
    ) else { return }
    await notifier.postNewArticles(count: inserted)
}
```

Update `runNow()`, the Mac `scheduleMac` loop, and `handle(task:)`'s work `Task` — each currently constructs `AggregationService(context: container.mainContext)` and passes it to `runRefresh(service:)`; replace with:
```swift
guard let client = AuthenticatedClient.current() else {
    task.setTaskCompleted(success: true)   // nothing to do without a paired session
    return
}
let engine = SyncEngine(container: container, client: client)
await Self.runRefresh(engine: engine)
```
(adjust the exact completion-handling per call site — `runNow()`/`scheduleMac` don't have a `BGTask` to complete, only `handle(task:)` does; keep each call site's existing surrounding structure, changing only the `AggregationService`→`SyncEngine` construction and the early-return-when-unpaired guard).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/BackgroundRefreshManagerTests` (adjust the `-only-testing` target name to whatever Step 1 actually found).
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/BackgroundRefreshManager.swift
git add -u YanaTests
git commit -m "BackgroundRefreshManager: sync via SyncEngine instead of AggregationService"
```

---

## Phase 6 — AI rework

### Task 15: Delete the 6-provider network AI stack

**Files:**
- Delete: `Yana/Services/AIClient.swift`, `Yana/Services/AIProcessor.swift`
- Delete: `Yana/Views/Config/Settings/AIProviderSettingsSection.swift`, `Yana/Views/Config/Settings/AITuningSettingsSection.swift`
- Delete: `Yana/Views/Config/Settings/RedditSettingsSection.swift`, `Yana/Views/Config/Settings/YouTubeSettingsSection.swift`
- Modify: `Yana/Services/CredentialTester.swift`
- Delete: `Yana/Services/AIReadiness.swift`, `YanaTests/AIReadinessTests.swift` (discovered during Task 3's build-verification pass, not in the original file inventory: `AIReadiness.isReady(provider:)` branches on the now-deleted `AIProvider` and `KeychainService.APIKeyItem` — it has no remaining purpose once there are only two AI modes, and Apple Intelligence availability is just `AppleIntelligenceClient().availability == .available` directly, no per-provider branching needed)

**Interfaces:** none new — pure deletion + one file trimmed to its still-useful part.

- [ ] **Step 1: Delete the network AI files**

```bash
git rm Yana/Services/AIClient.swift Yana/Services/AIProcessor.swift
git rm Yana/Views/Config/Settings/AIProviderSettingsSection.swift Yana/Views/Config/Settings/AITuningSettingsSection.swift
git rm Yana/Views/Config/Settings/RedditSettingsSection.swift Yana/Views/Config/Settings/YouTubeSettingsSection.swift
git rm Yana/Services/AIReadiness.swift YanaTests/AIReadinessTests.swift
```

**Do not yet touch `Yana/Reader/ReaderHostView.swift`/`Yana/Reader/Mac/TimelineModel.swift`**, even though both currently call the `AIReadiness.isReady(provider: settings.activeAIProvider)` you're deleting here (each via a private `aiReady: Bool` computed property gating the reader's "Summarize" toolbar button) — leaving them broken at this point is expected; Task 17 replaces both call sites with the new two-mode check when it wires `AISummaryProvider` into the same trigger point.

Note: `RedditClient.swift`/`YouTubeClient.swift`/`RedditModels.swift`/`YouTubeModels.swift`/`RedditMarkdown.swift` were already deleted in Task 12 (they lived under `Yana/Aggregators/Concrete/`). If any of those four Settings-section files still reference something not yet deleted, `grep -n "RedditClient\|YouTubeClient" Yana/Views/Config/Settings/*.swift` first to confirm — expected to find nothing left referencing them once this step's deletions land.

- [ ] **Step 2: Trim `CredentialTester.swift` to just `CredentialTestError`**

Delete the `reddit`, `youtube`, `ai`, and `aiBaseURL` static functions. `CredentialTesterTests.swift` (which only tests `CredentialTestError`, confirmed earlier) needs no changes.

```swift
import Foundation

enum CredentialTestError: Error, Equatable {
    case invalidCredentials
    case network
    case unexpectedResponse

    var localizedMessage: String {
        switch self {
        case .invalidCredentials: String(localized: "Invalid credentials. Check the values and try again.")
        case .network: String(localized: "Network error. Check your connection and try again.")
        case .unexpectedResponse: String(localized: "Unexpected response from the server.")
        }
    }
}
```

- [ ] **Step 3: Run the existing `CredentialTesterTests` to confirm they still pass**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CredentialTesterTests`
Expected: PASS (2 tests, unchanged).

- [ ] **Step 4: Commit**

```bash
git add Yana/Services/CredentialTester.swift
git rm Yana/Services/AIClient.swift Yana/Services/AIProcessor.swift Yana/Views/Config/Settings/AIProviderSettingsSection.swift Yana/Views/Config/Settings/AITuningSettingsSection.swift Yana/Views/Config/Settings/RedditSettingsSection.swift Yana/Views/Config/Settings/YouTubeSettingsSection.swift Yana/Services/AIReadiness.swift YanaTests/AIReadinessTests.swift
git commit -m "Delete the 6-provider network AI stack, Reddit/YouTube settings UI, and AIReadiness"
```

---

### Task 16: `AISummaryProvider` — Server (via `/ai/prompt`) and Apple Intelligence

**Files:**
- Create: `Yana/Services/AISummaryProvider.swift`
- Modify: `Yana/Services/AppleIntelligenceProcessor.swift` (trim to just the summarization chunking logic; rename per Step 4)
- Test: `YanaTests/AISummaryProviderTests.swift`

**Interfaces:**
- Produces:
```swift
protocol AISummaryProvider: Sendable {
    func summarize(content: String, title: String) async -> String?
}
struct ServerAISummaryProvider: AISummaryProvider { init(client: YanaAPIClient) }
struct AppleIntelligenceSummaryProvider: AISummaryProvider { init(generator: ArticleGenerating = AppleIntelligenceClient()) }
enum AISummaryReadiness { static func isReady(mode: AIMode) -> Bool }
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AISummaryProvider")
struct AISummaryProviderTests {
    @Test func serverProviderCallsAiPromptAndReturnsTheResponseText() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        var capturedPrompt: String?
        MockURLProtocol.stub = { request in
            capturedPrompt = String(data: request.httpBodyOrStream(), encoding: .utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, #"{"response":"A concise summary.","provider":"openai","model":"gpt-4o-mini"}"#.data(using: .utf8)!)
        }
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
        let provider = ServerAISummaryProvider(client: client)

        let summary = await provider.summarize(content: "Long article body...", title: "An Article")
        #expect(summary == "A concise summary.")
        #expect(capturedPrompt?.contains("An Article") == true)
    }

    @Test func serverProviderReturnsNilOnRateLimitRatherThanThrowing() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, #"{"error":{"code":"daily_limit_exceeded","message":"limit reached"}}"#.data(using: .utf8)!)
        }
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
        let provider = ServerAISummaryProvider(client: client)

        let summary = await provider.summarize(content: "x", title: "y")
        #expect(summary == nil)
    }
}

private extension URLRequest {
    func httpBodyOrStream() -> Data { httpBody ?? Data() }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AISummaryProviderTests`
Expected: FAIL — `AISummaryProvider`/`ServerAISummaryProvider` don't exist.

- [ ] **Step 3: Write `AISummaryProvider.swift`**

```swift
import Foundation

/// Produces the reader's summary block. Two implementations, selected by `AppSettings.aiMode`:
/// `ServerAISummaryProvider` (network, via the server's configured provider) and
/// `AppleIntelligenceSummaryProvider` (on-device). Both degrade to `nil` on any failure --
/// "no summary available" is an expected, silent outcome here (rate limit, no provider
/// configured, model unavailable), never a user-facing error.
protocol AISummaryProvider: Sendable {
    func summarize(content: String, title: String) async -> String?
}

/// Whether the reader's "Summarize" action should be offered at all, for a given mode.
/// `.server` is always considered ready -- `ServerAISummaryProvider` degrades to `nil` on its
/// own if the server has no provider configured, which is a fine outcome for a button that was
/// visible; `.appleIntelligence` needs an actual on-device-model availability check, since
/// showing the button with no usable model is a worse experience than hiding it. Shared here so
/// `ReaderHostView`/`TimelineModel`'s toolbar-visibility checks (Task 17) don't duplicate the
/// same three-line switch in two files.
enum AISummaryReadiness {
    static func isReady(mode: AIMode) -> Bool {
        switch mode {
        case .server: true
        case .appleIntelligence: AppleIntelligenceClient().availability == .available
        }
    }
}

private struct AIPromptBody: Encodable { let prompt: String }
private struct AIPromptResponse: Decodable { let response: String; let provider: String; let model: String }

struct ServerAISummaryProvider: AISummaryProvider {
    let client: YanaAPIClient

    func summarize(content: String, title: String) async -> String? {
        let prompt = "Summarize the following article concisely in 2-3 sentences.\n\nTitle: \(title)\n\n\(content)"
        do {
            let result: AIPromptResponse = try await client.post("/api/v1/ai/prompt", body: AIPromptBody(prompt: prompt))
            return result.response
        } catch {
            // 429 (daily/monthly limit), 409 (no provider configured), 502 (provider error) all
            // land here as ordinary, expected "no summary this time" outcomes.
            return nil
        }
    }
}

struct AppleIntelligenceSummaryProvider: AISummaryProvider {
    let generator: ArticleGenerating

    init(generator: ArticleGenerating = AppleIntelligenceClient()) {
        self.generator = generator
    }

    func summarize(content: String, title: String) async -> String? {
        guard generator.availability == .available else { return nil }
        return await AppleIntelligenceChunkedSummarizer.summarize(html: content, title: title, generator: generator)
    }
}
```

- [ ] **Step 4: Extract the chunking logic from `AppleIntelligenceProcessor.swift`**

Rename `Yana/Services/AppleIntelligenceProcessor.swift` → `Yana/Services/AppleIntelligenceChunkedSummarizer.swift`:
```bash
git mv Yana/Services/AppleIntelligenceProcessor.swift Yana/Services/AppleIntelligenceChunkedSummarizer.swift
```
Delete the `AIProcessing` conformance, `process(_:ai:)`, `processOne(...)`'s improveWriting/translate branches, and every `[AggregatedArticle]`/`AIOptions` reference (those types no longer exist post-Task-12). Keep exactly the chunk+reduce math (`contextWindowTokens`, `outputReserveTokens`, `instructionReserveTokens`, `contentBudgetTokens`) and the `summarize(html:title:)` method (lines 91–113 per the earlier research), repackaged as:
```swift
enum AppleIntelligenceChunkedSummarizer {
    private static let contextWindowTokens = 4096
    private static let outputReserveTokens = 1200
    private static let instructionReserveTokens = 400
    // ... (carry over the exact chunk-splitting + per-chunk generateSummary + reduce-if-multiple-chunks logic from the old summarize(html:title:) method, unchanged, just no longer a method on a type conforming to the deleted AIProcessing protocol)

    static func summarize(html: String, title: String, generator: ArticleGenerating) async -> String? {
        // body carried over verbatim from AppleIntelligenceProcessor.summarize(html:title:)
    }
}
```
Do this as a careful move-and-trim of the actual existing method body (read the file first — it wasn't reproduced in full in this plan since it's substantial and copying it here secondhand risks a transcription error against real chunking math). Do not rewrite the chunking algorithm from scratch; only delete what's unrelated to summarization and adjust the enclosing type.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AISummaryProviderTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AISummaryProvider.swift Yana/Services/AppleIntelligenceChunkedSummarizer.swift YanaTests/AISummaryProviderTests.swift project.yml
git commit -m "Add AISummaryProvider: server-mediated (/ai/prompt) and Apple Intelligence summaries"
```

---

### Task 17: Two-option AI mode Settings UI; wire the summary trigger point

**Files:**
- Create: `Yana/Views/Config/Settings/AIModeSettingsSection.swift`
- Modify: the reader's summary-generation trigger point (locate with `grep -rn "runSummarize\|\.summarize(" Yana --include="*.swift"` — the old trigger was `AggregationService.summarize(_:)`, already deleted in Task 12; find whatever reader/toolbar action called it)
- Modify: `Yana/Reader/ReaderHostView.swift:167` and `Yana/Reader/Mac/TimelineModel.swift:127` — both currently have a private/internal `aiReady: Bool { AIReadiness.isReady(provider: settings.activeAIProvider) }` computed property gating the "Summarize" toolbar button's visibility (broken since Task 15 deleted `AIReadiness`/`AIProvider`/`activeAIProvider`; discovered during Task 3's build-verification pass, not in the original plan). Replace both with `AISummaryReadiness.isReady(mode: settings.aiMode)` — the shared helper Task 16 adds to `Yana/Services/AISummaryProvider.swift` for exactly this, so the two-mode check isn't duplicated across `ReaderHostView`/`TimelineModel`.

**Interfaces:**
- Produces: `struct AIModeSettingsSection: View`.

No new automated test — this is a `Picker` wiring task; verify manually per Step 3 plus the existing `AISummaryProviderTests` covering the underlying logic.

- [ ] **Step 1: Write `AIModeSettingsSection.swift`**

```swift
import SwiftUI

struct AIModeSettingsSection: View {
    @State private var settings = AppSettings()
    @State private var appleIntelligenceStatus: AppleIntelligenceAvailability?

    var body: some View {
        Section {
            Picker("AI Mode", selection: Binding(
                get: { settings.aiMode },
                set: { settings.aiMode = $0 }
            )) {
                ForEach(AIMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if settings.aiMode == .appleIntelligence {
                LabeledContent("Status") {
                    Text(statusText)
                }
            }
        } footer: {
            Text("Server mode uses whatever AI provider you've configured on the server. Apple Intelligence runs entirely on this device.")
        }
        .task { appleIntelligenceStatus = AppleIntelligenceClient().availability }
    }

    private var statusText: String {
        switch appleIntelligenceStatus {
        case .available: String(localized: "Available")
        case .deviceNotEligible: String(localized: "Device Not Eligible")
        case .notEnabled: String(localized: "Not Enabled")
        case .modelNotReady: String(localized: "Model Not Ready")
        case nil: String(localized: "Checking…")
        }
    }
}
```

Add the four new/reused strings (`"AI Mode"`, `"Available"`, `"Device Not Eligible"`, `"Not Enabled"`, `"Model Not Ready"`, `"Checking…"`, the footer sentence) to `Yana/Resources/Localizable.xcstrings` in English and German, `"state": "translated"` — check first whether the status strings already exist from the deleted `AIProviderSettingsSection` (likely yes, in which case reuse the existing keys rather than duplicating).

- [ ] **Step 2: Wire the summary trigger point**

At the reader action found via the grep above (a toolbar "Summarize" button or equivalent), replace the deleted `AggregationService.summarize(_:)` call with:
```swift
let provider: AISummaryProvider = settings.aiMode == .appleIntelligence
    ? AppleIntelligenceSummaryProvider()
    : ServerAISummaryProvider(client: client)   // `client` from AuthenticatedClient.current(), guarded
guard let summary = await provider.summarize(content: article.plainText, title: article.title) else { return }
article.summary = summary
try? modelContext.save()
```

- [ ] **Step 3: Manual verification**

Build and run in the Simulator; open Settings, confirm the AI Mode picker shows exactly "Server" / "Apple Intelligence" with no leftover provider/key fields; switch to Apple Intelligence and confirm the status row reflects `AppleIntelligenceClient().availability` on this Simulator (expected `.deviceNotEligible` or similar on Simulator hardware — that's fine, it's the real on-device check, not a stub).

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/Settings/AIModeSettingsSection.swift Yana/Resources/Localizable.xcstrings
git add -u
git commit -m "Add the two-option AI mode Settings section; wire the summary trigger to AISummaryProvider"
```

---

## Phase 7 — WebView management, Settings, onboarding

### Task 18: Management WebView screen

**Files:**
- Create: `Yana/Views/ManagementWebView.swift`

**Interfaces:**
- Produces: `struct ManagementWebView: View { let serverBaseURL: URL; var path: String = "/feeds" }`.

No automated test (live WebView against a real server). Verify manually per Step 2.

- [ ] **Step 1: Write `ManagementWebView.swift`**

```swift
import SwiftUI
import WebKit

/// Hosts the server's own feed/tag/settings web UI, reusing the pairing flow's persistent
/// cookie session (`WKWebsiteDataStore.default()`) so a user who just paired isn't asked to log
/// in again to reach these pages.
struct ManagementWebView: View {
    let serverBaseURL: URL
    var path: String = "/feeds"

    var body: some View {
        ManagementWKWebView(url: serverBaseURL.appendingPathComponent(path))
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ManagementWKWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
```

- [ ] **Step 2: Manual verification (defer to Task 19/21's wiring)**

Note in the commit message that end-to-end verification (confirm the WebView loads the feeds page already signed in, without a fresh login prompt) happens once Task 21 wires this into Settings with a real paired session to test against.

- [ ] **Step 3: Commit**

```bash
git add Yana/Views/ManagementWebView.swift
git commit -m "Add ManagementWebView: hosts the server's feed/tag/settings web UI"
```

---

### Task 19: Delete native feed/tag management; redirect the reader's "add feed" quick action

**Files:**
- Delete: `Yana/Views/Config/FeedsView.swift`, `TagsView.swift`, `FeedEditorView.swift`, `AggregatorOptionsForm.swift`, `Yana/Views/Config/FeedEditorModel.swift` (+ `YanaTests/FeedEditorModelTests.swift` — discovered during Task 7's execution: this is `FeedEditorView`'s view model, a separate file, not a private type, tightly coupled to the deleted `AggregatorType`/`AggregatorOptions` and left broken since Task 7; not on the original inventory), and any separate `FeedTagsPicker.swift`/`TagEditorView.swift` files (`grep -rln "struct FeedTagsPicker\|struct TagEditorView" Yana` to find exact file names — some of these were private types inside `FeedsView.swift`/`TagsView.swift`/`FeedEditorView.swift` per the earlier research and are deleted along with those files, not separately)
- Delete: `Yana/Views/Config/SelectorListView.swift`, `Yana/Services/SelectorSuggester.swift`, `YanaTests/SelectorSuggesterTests.swift` (discovered during Task 3's build-verification pass, not in the original file inventory: `SelectorListView` is the CSS-selector editor for the on-device full-website scraper's content/ignore lists, used only from `AggregatorOptionsForm.swift` — confirmed via `grep -rn "SelectorListView(" Yana`, one call site, both inside the file being deleted here. `SelectorSuggester` is its "auto-generate with AI" helper, with no other caller.)
- Modify: `Yana/Reader/ReaderHostView.swift`, `Yana/Reader/Mac/MacRootView.swift` (the two "add feed" quick-action sheets found in prior research, at `ReaderHostView.swift:221-227` and `MacRootView.swift:44-51`)

**Interfaces:** none new.

- [ ] **Step 1: Delete the feed/tag management views**

```bash
grep -rln "struct FeedTagsPicker\|struct TagEditorView\|struct AggregatorOptionsForm" Yana
```
`git rm` `FeedsView.swift`, `TagsView.swift`, `FeedEditorView.swift`, and any additional files that search surfaces beyond those three (if `FeedTagsPicker`/`TagEditorView`/`AggregatorOptionsForm` are private types *inside* those three files, as the earlier research suggests, there's nothing extra to remove here).

```bash
git rm Yana/Views/Config/FeedsView.swift Yana/Views/Config/TagsView.swift Yana/Views/Config/FeedEditorView.swift Yana/Views/Config/AggregatorOptionsForm.swift
git rm Yana/Views/Config/SelectorListView.swift Yana/Services/SelectorSuggester.swift YanaTests/SelectorSuggesterTests.swift
```

- [ ] **Step 2: Redirect `ReaderHostView.swift`'s quick action**

Replace:
```swift
.sheet(isPresented: $showingCreateFeed) {
    NavigationStack {
        FeedEditorView(feed: nil) { newFeed in
            guard newFeed.enabled else { return }
            createFeed(newFeed)
        }
    }
}
```
with:
```swift
.sheet(isPresented: $showingCreateFeed) {
    NavigationStack {
        ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!, path: "/feeds/new")
    }
}
```
Delete the now-unused `createFeed(_:)` helper this replaced, if nothing else calls it (`grep -n "func createFeed" Yana/Reader/ReaderHostView.swift` to confirm it's private and this was its only call site).

- [ ] **Step 3: Apply the same change to `MacRootView.swift`**

```swift
.sheet(isPresented: $showingCreateFeed) {
    NavigationStack {
        ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!, path: "/feeds/new")
    }
}
```
Delete the `UpdateActivity.shared.restart { ... AggregationService(context:).update(feed: newFeed) }` block this replaced — it referenced the now-deleted `AggregationService`.

- [ ] **Step 4: Confirm no other call sites remain**

Run: `grep -rn "FeedEditorView\|FeedsView(\|TagsView(" Yana --include="*.swift"`
Expected: no output (Task 20 handles the `WelcomeView.swift:420` occurrence; if that's the *only* remaining hit, it's expected at this point and closed out in Task 22 — everything else must be zero).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Delete native Feeds/Tags/FeedEditor screens; add-feed quick action opens the WebView"
```

---

### Task 20: Delete OPML

**Files:**
- Delete: `Yana/Services/FeedPortability.swift`, `Yana/Services/OPMLCodec.swift`
- Delete any orphaned tests: `grep -rln "FeedPortability\|OPMLCodec" YanaTests`

**Interfaces:** none — pure deletion, confirmed by the spec's explicit "drop OPML entirely" decision, and by Task 19 already having removed `FeedsView`'s import/export menu (its only remaining native UI hook, besides `WelcomeView`'s import button, closed out in Task 22).

- [ ] **Step 1: Delete the files**

```bash
git rm Yana/Services/FeedPortability.swift Yana/Services/OPMLCodec.swift
grep -rln "FeedPortability\|OPMLCodec" YanaTests
```
`git rm` whatever that last grep finds.

- [ ] **Step 2: Confirm no remaining reference**

Run: `grep -rn "FeedPortability\|OPMLCodec\|importOPML\|exportOPML" Yana --include="*.swift"`
Expected: no output (the one remaining call site, `WelcomeView.swift`'s `handleImport`, is removed in Task 22 alongside the rest of the old onboarding-feeds page — if this grep still shows that single hit right now, that's expected and fine to leave until Task 22).

- [ ] **Step 3: Commit**

```bash
git rm Yana/Services/FeedPortability.swift Yana/Services/OPMLCodec.swift
git commit -m "Delete OPML import/export (no server equivalent; feed management moved to the WebView)"
```

---

### Task 21: Rework `SettingsScreenView` and `MacSettingsWindow`

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift`
- Modify: `Yana/Reader/Mac/MacSettingsWindow.swift`

**Interfaces:** none new — pure recomposition of existing section views plus the new `AIModeSettingsSection` (Task 17) and `ManagementWebView` (Task 18).

- [ ] **Step 1: Rewrite `SettingsScreenView.swift`'s body**

Replace `organizeSection`'s two `NavigationLink`s (Feeds/Tags) with one entry point into the WebView, and drop `RedditSettingsSection`/`YouTubeSettingsSection`/`AIProviderSettingsSection`/`AITuningSettingsSection` in favor of `AIModeSettingsSection`:

```swift
var body: some View {
    Form {
        manageSection
        ReaderSettingsSection()
        AIModeSettingsSection()
        NotificationsSettingsSection()
        LibrarySettingsSection()
        AboutSettingsSection(
            onRestartOnboarding: { onRestartOnboarding(); dismiss() },
            onShowServerNotice: { onShowServerNotice(); dismiss() },
            onRevealDiagnostics: {}
        )
    }
    .toggleStyle(.switch)
    .navigationTitle("Settings")
    .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Close"))
        }
    }
    .toast($toast)
}

private var manageSection: some View {
    Section {
        NavigationLink {
            ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!)
        } label: {
            Label("Manage Feeds & Tags", systemImage: "list.bullet.rectangle")
                .labelStyle(.tintedIcon(.orange))
        }
        .accessibilityIdentifier("settings.manage")
    } footer: {
        Text("Add, edit, and organize your feeds and tags on the server.")
    }
}
```

`LibrarySettingsSection` (per the earlier research, retention-days/update-interval) needs its own follow-up check: retention is now server-side only per the spec, so open that file and remove any retention-days control that still writes a local setting the app no longer reads (`grep -n "retentionDays" Yana/Views/Config/Settings/LibrarySettingsSection.swift Yana/Models/AppSettings.swift` — if `AppSettings.retentionDays` still exists and is now unused, delete both the control and the property as part of this step, not a separate task, since you're already in this file).

Add the two new/changed strings (`"Manage Feeds & Tags"`, the footer sentence) to `Localizable.xcstrings`.

- [ ] **Step 2: Rewrite `MacSettingsWindow.swift`'s `SettingsPane`/`detail`**

Remove the `.feeds`/`.tags`/`.integrations`/`.diagnostics` cases from `SettingsPane` (the `.diagnostics` case is already being removed by the separately-tracked background task from the design-review pass — if that task has landed by the time this one runs, this pane is already gone; if not, remove it here too rather than leaving it half-dead a second time) and the corresponding `detail` branches; add `.manage` (→ `ManagementWebView`) and change `.ai` to render `AIModeSettingsSection()`:

```swift
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reader, manage, ai, about
    // ... title/systemImage unchanged for surviving cases, new entries for .manage
}
```
```swift
case .manage:
    ManagementWebView(serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!)
case .ai:
    Form { AIModeSettingsSection() }
```
Remove `visiblePanes`'s `DiagnosticsReveal` gating if that type is already gone (per the background task); otherwise leave the gating logic as-is for now and let that other task finish removing it, to avoid two tasks editing the same lines out of sync — check `grep -n "DiagnosticsReveal" Yana/Reader/Mac/MacSettingsWindow.swift` immediately before this step and adapt based on what you find.

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: the iOS target builds cleanly. (Mac Catalyst is out of scope for this build check — verify it separately if the earlier-spawned Mac-Catalyst-build-fix task has landed; if not, its pre-existing breakage is unrelated to this task and shouldn't block it.)

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Reader/Mac/MacSettingsWindow.swift Yana/Resources/Localizable.xcstrings
git commit -m "Rework Settings: drop Feeds/Tags/Integrations/AI-provider panes for the WebView + AI mode"
```

---

### Task 22: `WelcomeView` 3-step rework; `ContentView` re-pairing gate

**Files:**
- Modify: `Yana/Views/WelcomeView.swift`
- Modify: `Yana/ContentView.swift`

**Interfaces:**
- Modifies: `WelcomeView.Step` from `{welcome, ai, feeds}` to `{welcome, server, aiMode}`; adds `WelcomeView.init(initialStep: Step = .welcome, onFinish: @escaping () -> Void)` so a re-pairing flow (session revoked/cleared) can jump straight to `.server` instead of restarting from `.welcome`.

- [ ] **Step 1: Rewrite the `Step` enum and page switch**

```swift
private enum Step: Int, CaseIterable {
    case welcome, server, aiMode
}
```
```swift
switch step {
case .welcome: WelcomeIntroPage()
case .server: OnboardingServerPage(onPaired: { step = .aiMode })
case .aiMode: OnboardingAIModePage()
}
```

- [ ] **Step 2: Write `OnboardingServerPage` (new file, `Yana/Views/Onboarding/OnboardingServerPage.swift`)**

```swift
import SwiftUI

struct OnboardingServerPage: View {
    let onPaired: () -> Void

    @State private var settings = AppSettings()
    @State private var serverURLText = ""
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                TextField("https://your-server.example.com", text: $serverURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server Address")
            } footer: {
                Text("Yana needs a Yana Server to sign in and sync your feeds.")
            }

            Section {
                Button("Sign In") { isPairing = true }
                    .disabled(URL(string: serverURLText) == nil)
            }
        }
        .onAppear { serverURLText = settings.serverBaseURL }
        .sheet(isPresented: $isPairing) {
            if let url = URL(string: serverURLText) {
                DevicePairingView(
                    serverBaseURL: url,
                    onPaired: { token in
                        settings.serverBaseURL = serverURLText
                        KeychainService.saveDeviceToken(token)
                        isPairing = false
                        onPaired()
                    },
                    onCancel: { isPairing = false }
                )
            }
        }
    }
}
```

Add `"Server Address"`, `"https://your-server.example.com"` (as a hint, may not need localization if treated as a placeholder example — still add it, since `Localizable.xcstrings` covers all user-facing strings per the project rule), `"Yana needs a Yana Server to sign in and sync your feeds."`, `"Sign In"` to `Localizable.xcstrings` in English and German.

- [ ] **Step 3: Write `OnboardingAIModePage` (new file, `Yana/Views/Onboarding/OnboardingAIModePage.swift`)**

```swift
import SwiftUI

struct OnboardingAIModePage: View {
    var body: some View {
        Form {
            AIModeSettingsSection()
        }
    }
}
```

(Reuses Task 17's section verbatim — the onboarding step and the Settings screen show identical content by design, so there's exactly one implementation to keep correct.)

- [ ] **Step 4: Delete `OnboardingAIPage`/`OnboardingFeedsPage`**

Delete both private structs from `Yana/Views/WelcomeView.swift` entirely (they're replaced by Steps 2-3's new pages). This also removes `WelcomeView.swift`'s remaining `FeedEditorView(feed: nil) { _ in }` and `FeedPortability.importOPML` call sites — the last two references either of those had anywhere in the app (confirmed empty by Tasks 19/20's earlier greps once this step lands).

- [ ] **Step 5: Update `finish()`**

Replace:
```swift
UpdateActivity.shared.restart { _ = await AggregationService(context: modelContext).updateAll() }
```
with a first foreground sync now that pairing is complete:
```swift
Task {
    guard let client = AuthenticatedClient.current() else { return }
    _ = try? await SyncEngine(container: AppContainer.shared, client: client).sync()
}
```

- [ ] **Step 6: Add `initialStep` and wire `ContentView`'s re-pairing gate**

```swift
private enum Step: Int, CaseIterable { case welcome, server, aiMode }

struct WelcomeView: View {
    let onFinish: () -> Void
    var initialStep: Step = .welcome
    @State private var step: Step

    init(onFinish: @escaping () -> Void, initialStep: Step = .welcome) {
        self.onFinish = onFinish
        self.initialStep = initialStep
        self._step = State(initialValue: initialStep)
    }
    // ...
}
```

In `Yana/ContentView.swift`'s `.onAppear`, add a re-pairing condition alongside the existing onboarding check — a device that completed onboarding once but has no valid token any more (session revoked from another device, or the user deleted the app's Keychain data) should re-enter `WelcomeView` starting at `.server`, not `.welcome`:
```swift
if !settings.hasCompletedOnboarding, !Self.skipOnboarding {
    appState.welcomeInitialStep = .welcome
    appState.showWelcome = true
} else if settings.hasCompletedOnboarding, AuthenticatedClient.current() == nil, !Self.skipOnboarding {
    appState.welcomeInitialStep = .server
    appState.showWelcome = true
}
```
(Add `welcomeInitialStep: WelcomeView.Step = .welcome` to `AppState`, and pass it through the `WelcomeView(...)` construction in the `fullScreenCover`. Note `WelcomeView.Step` is currently `private` — change it to internal, since `AppState` now needs to reference it.)

- [ ] **Step 7: Build and manually verify the full pairing flow**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`

Manually: run the app fresh (reset onboarding via `-UITEST_RESET_ONBOARDING` or a clean Simulator), step through welcome → enter a real or locally-run yana-server's URL → sign in via the pairing WebView → confirm the `yana://auth-callback` intercept fires, the token lands in Keychain, and the app proceeds to the AI-mode step → Finish → confirm a first sync populates the timeline.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Rework onboarding to 3 steps: welcome, server pairing, AI mode

Adds a re-pairing gate in ContentView for a device that completed
onboarding once but has no valid session any more."
```

---

## Phase 8 — Final verification

### Task 23: Full build/test pass, doc refresh

**Files:**
- No new files. Runs the full suite and the project's documentation-update skill.

- [ ] **Step 1: Full clean build**

```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' clean build
```
Expected: succeeds with zero errors. If anything still references a deleted type, fix it now — by this point every deletion in this plan has landed, so any remaining reference is a genuine miss, not an expected pending task.

- [ ] **Step 2: Full test run**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: all tests pass. Note: `YanaUITests` (screenshot/UI tests) are **expected to fail or need rework** at this point — `ScreenshotUITests`' `05_AI` shot and its caption still reference the old bring-your-own-key AI section (a known, already-flagged-in-the-spec follow-up, not part of this plan's scope). Confirm failures are isolated to that known area; anything else failing is a genuine regression to fix.

- [ ] **Step 3: Grep-sweep for leftover references to everything this plan deleted**

```bash
grep -rn "AggregatorType\|AggregatorOptions\|AggregationService\|AggregationWriter\|ArticleUID\|StarredRegistry\|StoredImage\|ImageSync\b\|AIClient\b\|AIProcessor\b\|FeedPortability\|OPMLCodec\|FeedEditorView\|isBuiltIn" Yana --include="*.swift"
```
Expected: no output. Investigate and fix anything this finds — it means a task above missed a call site.

- [ ] **Step 4: Refresh `CLAUDE.md`**

Invoke the `updating-project-docs` skill now (it's designed for exactly this point — "about to commit after code changes... codebase may have diverged from documentation"). `CLAUDE.md`'s Architecture section is comprehensively wrong after this rework (it describes on-device aggregation, 7 AI providers, CloudKit sync that's already gone, OPML, Reddit/YouTube credential management — none of which exist any more) and needs a full rewrite of the affected sections, not incremental patching. This is intentionally the last task in this plan rather than done incrementally per-task, since documenting a moving target task-by-task would mean rewriting the same paragraphs repeatedly.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "Rewrite CLAUDE.md's architecture docs for the server-API client rework"
```

---

## Self-Review Notes

**Spec coverage check** (against `docs/superpowers/specs/2026-08-05-server-api-client-rework-design.md`):
- Auth/device pairing → Tasks 2-4, 22. ✓
- Sync engine, offline-first, backfill, pagination → Tasks 9-10. ✓
- Block wire-format decode (spec didn't call this out explicitly, but it's a load-bearing prerequisite the spec's Architecture section assumed away — caught during this plan's own research) → Task 5. ✓
- Starred boolean, tag filtering live-join → Task 6. ✓ (`read` field: intentionally undecoded-into-behavior per spec — `SyncArticleSummaryWire.read` exists on the wire type in Task 9 but nothing reads `Article`'s copy of it, matching "decoded but never acted on.")
- Images/logos eager fetch-by-hash, 64MB cap carried over → Task 11. ✓
- Removed-wholesale file list → Tasks 7, 8, 12, 15, 19, 20. ✓ (cross-checked against the spec's exact file lists in "Aggregators/ disposition" and "Removed wholesale")
- AI: two modes, `/ai/prompt`, Apple Intelligence kept → Tasks 15-17. ✓
- WebView management → Tasks 18-19, 21. ✓
- Onboarding 3 steps, re-pairing gate → Task 22. ✓
- Background refresh via SyncEngine → Task 14. ✓
- URL scheme registration (spec flagged as net-new) → Task 3. ✓
- Custom URL scheme + `ArticleUID`/`AggregatorType` deletion → Tasks 3, 7, 8. ✓
- App Store screenshot caption update (spec's own "out of scope, tracked here") → deliberately **not** a task in this plan, matching the spec's own scoping; Task 23 Step 2 surfaces it again as an expected test failure rather than silently ignoring it.
- Mac Catalyst SyncLogView/diagnostics pre-existing bug (spec's own "flagged separately") → deliberately **not** a task here either; Task 21 Step 2 explicitly checks whether that separate fix has landed before touching the same lines, to avoid two uncoordinated edits.

**Placeholder scan:** no "TBD"/"handle appropriately" found on review. Two spots are intentionally deferred with a concrete reason rather than filled with invented code: Task 11 Step 6's `// TODO(Task 12)` (resolved one task later, not left open at the plan's end) and Task 16 Step 4's "read the file first, don't transcribe secondhand" instruction for the chunking math (a deliberate choice to avoid shipping a plan that silently mis-copies token-budget arithmetic it never actually re-verified against the real file).

**Type consistency check:** `Article.serverID: Int?` (Task 9) is used consistently as the upsert/removal/backfill key through Tasks 9-14. `SyncResult.newCount` (Task 10) matches what Task 14's `runRefresh` reads. `AISummaryProvider.summarize(content:title:)` (Task 16) matches both call sites (Task 17 Step 2, and `AppleIntelligenceSummaryProvider`'s own internal call into `AppleIntelligenceChunkedSummarizer.summarize(html:title:generator:)`). `AIMode` (Task 3) is referenced identically in Tasks 16-17 and 21-22.

---

Plan complete and saved to `docs/superpowers/plans/2026-08-05-server-api-client-rework.md`.
