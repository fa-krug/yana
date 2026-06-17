# Apple Intelligence (on-device) AI Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple's on-device Foundation Models (iOS 26) as a no-key, no-network AI post-processing provider (`AIProvider.appleIntelligence`) that performs summarize / improveWriting / translate via chunk + map-reduce, alongside the existing HTTP providers.

**Architecture:** A new `AppleIntelligenceClient` wraps `FoundationModels` (availability + guided generation + token counting) behind an injectable `ArticleGenerating` protocol. A new `AppleIntelligenceProcessor` (an `AIProcessing` conformer parallel to `AIProcessor`) chunks long article HTML on block boundaries, maps each chunk through the model, and reduces when summarize is on. A factory in `AggregationService` picks the processor by provider. External providers are untouched.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, SwiftSoup (HTML), `FoundationModels` (iOS 26), Swift Testing (`import Testing`).

## Global Constraints

- Platform floor iOS 26.0 — `FoundationModels` is always importable; **no `@available` guards needed**.
- Scope is **on-device only**. Private Cloud Compute / WWDC 2026 Foundation Models features are out of scope.
- External providers (OpenAI/Anthropic/Gemini) stay fully intact; this work is additive.
- Strict concurrency: new shared types are `Sendable`; UI types stay `@MainActor`.
- Model-unavailability → **passthrough** (article unmodified). Per-article generation failure → **drop** (parity with `AIProcessor`).
- All new user-facing strings get `en` + `de` entries in `Localizable.xcstrings`, `state: translated`, Apple German style (infinitive, no Du/Sie).
- Tests never touch `SystemLanguageModel`/`LanguageModelSession` (unavailable on CI); use injected fakes.

---

### Task 1: Add the `appleIntelligence` provider case

**Files:**
- Modify: `Yana/Models/AppSettings.swift:3-32` (enum `AIProvider`)
- Modify: `Yana/Services/AIClient.swift:64-69` (exhaustive `switch` in `buildRequest`)
- Modify: `Yana/Services/AggregationService.swift:52-65` (exhaustive `switch` in `makeAIConfig`)
- Test: `YanaTests/AIProviderTests.swift` (create)

**Interfaces:**
- Produces: `AIProvider.appleIntelligence` with `displayName == "Apple Intelligence"` and `models == []`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AIProviderTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct AIProviderTests {
    @Test func appleIntelligenceHasNoModelsAndBrandName() {
        #expect(AIProvider.appleIntelligence.models.isEmpty)
        #expect(AIProvider.appleIntelligence.displayName == "Apple Intelligence")
        #expect(AIProvider.allCases.contains(.appleIntelligence))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProviderTests`
Expected: FAIL — `appleIntelligence` is not a member of `AIProvider`.

- [ ] **Step 3: Add the enum case and exhaustive-switch arms**

In `Yana/Models/AppSettings.swift`, add the case and switch arms:

```swift
enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case none
    case openai
    case anthropic
    case gemini
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    var models: [String] {
        switch self {
        case .none: []
        case .openai: ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini", "o3"]
        case .anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .appleIntelligence: []
        }
    }

    var defaultModel: String { models.first ?? "" }
}
```

In `Yana/Services/AIClient.swift`, `buildRequest` (the Apple path never reaches `AIClient`, but the switch must stay exhaustive):

```swift
        switch config.provider {
        case .openai: return (try openaiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseOpenAI)
        case .anthropic: return (try anthropicRequest(prompt: prompt), Self.parseAnthropic)
        case .gemini: return (try geminiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseGemini)
        case .none, .appleIntelligence: throw AIClientError.unsupportedProvider
        }
```

In `Yana/Services/AggregationService.swift`, `makeAIConfig` switch — Apple needs no model/key:

```swift
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
        case .appleIntelligence:
            model = ""
            keyItem = nil
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Services/AIClient.swift Yana/Services/AggregationService.swift YanaTests/AIProviderTests.swift
git commit -m "feat: add appleIntelligence AI provider case"
```

---

### Task 2: Extract shared `ArticleAIText` helpers

**Files:**
- Create: `Yana/Services/ArticleAIText.swift`
- Modify: `Yana/Services/AIProcessor.swift` (delegate `maxContentChars`, `cap`, `stripChrome`, and the per-task instruction strings to `ArticleAIText`)
- Test: `YanaTests/ArticleAITextTests.swift` (create)

**Interfaces:**
- Produces:
  - `ArticleAIText.maxContentChars: Int` (`50_000`)
  - `ArticleAIText.cap(_ html: String) -> String`
  - `ArticleAIText.stripChrome(_ html: String) throws -> String`
  - `ArticleAIText.summarizeInstruction: String`
  - `ArticleAIText.improveWritingInstruction: String`
  - `ArticleAIText.translateInstruction(language: String) -> String`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleAITextTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct ArticleAITextTests {
    @Test func capTruncatesAtBudget() {
        let long = String(repeating: "a", count: ArticleAIText.maxContentChars + 10)
        #expect(ArticleAIText.cap(long).count == ArticleAIText.maxContentChars)
        #expect(ArticleAIText.cap("short") == "short")
    }

    @Test func stripChromeRemovesChrome() throws {
        let html = "<header>h</header><p>body</p><footer>f</footer><script>x</script>"
        let cleaned = try ArticleAIText.stripChrome(html)
        #expect(cleaned.contains("body"))
        #expect(!cleaned.contains("<header>"))
        #expect(!cleaned.contains("<footer>"))
        #expect(!cleaned.contains("<script>"))
    }

    @Test func translateInstructionMentionsLanguage() {
        #expect(ArticleAIText.translateInstruction(language: "German").contains("German"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleAITextTests`
Expected: FAIL — `ArticleAIText` is undefined.

- [ ] **Step 3: Create `ArticleAIText` and re-point `AIProcessor` at it**

Create `Yana/Services/ArticleAIText.swift`:

```swift
import Foundation
import SwiftSoup

/// Pure, `Sendable` text helpers shared by the HTTP `AIProcessor` and the on-device
/// `AppleIntelligenceProcessor`: HTML chrome stripping, the content-size cap, and the
/// server-parity per-task instruction strings. Single source of truth for both paths.
enum ArticleAIText {
    /// Upper bound on characters of article HTML sent to any model.
    static let maxContentChars = 50_000

    /// Truncate to the character budget (no-op when already within it).
    static func cap(_ html: String) -> String {
        html.count <= maxContentChars ? html : String(html.prefix(maxContentChars))
    }

    /// Remove header/footer/nav/script/style; return the sanitized document HTML.
    static func stripChrome(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        for tag in ["header", "footer", "nav", "script", "style"] {
            try doc.select(tag).remove()
        }
        return try doc.html()
    }

    static let summarizeInstruction =
        "Summarize the article content concisely."

    static let improveWritingInstruction =
        "Rewrite the content to improve clarity, flow, and style. "
        + "IMPORTANT: Preserve the complete HTML structure including all tags. "
        + "Keep all links (<a> tags) exactly as they are - do not modify href attributes or remove any links. "
        + "Only improve the text content itself."

    static func translateInstruction(language: String) -> String {
        let targetLang = language.isEmpty ? "English" : language
        return "Translate the title and content to \(targetLang). "
            + "IMPORTANT: Do NOT translate link labels (the text inside <a> tags). "
            + "Keep link text in the original language. Only translate regular text content."
    }
}
```

In `Yana/Services/AIProcessor.swift`, delete the local `maxContentChars`/`cap`/`stripChrome` definitions (lines 73-93) and the inline instruction strings inside `buildPrompt`, replacing usages so behavior is identical:

- Replace `Self.cap(...)` → `ArticleAIText.cap(...)` and `Self.stripChrome(...)` → `ArticleAIText.stripChrome(...)` at the call site (line 56).
- In `buildPrompt`, replace the three inline task blocks with the shared strings:

```swift
        if ai.summarize {
            parts.append(ArticleAIText.summarizeInstruction)
        }
        if ai.improveWriting {
            parts.append(ArticleAIText.improveWritingInstruction)
        }
        if ai.translate {
            parts.append(ArticleAIText.translateInstruction(language: ai.translateLanguage))
        }
```

Leave the JSON-format boilerplate paragraphs and `extractJSON` in `AIProcessor` unchanged.

- [ ] **Step 4: Run the full AIProcessor + new tests to verify no regression**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleAITextTests -only-testing:YanaTests/AIProcessorTests`
Expected: PASS (existing `AIProcessorTests` still green — the refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleAIText.swift Yana/Services/AIProcessor.swift YanaTests/ArticleAITextTests.swift
git commit -m "refactor: extract shared ArticleAIText helpers from AIProcessor"
```

---

### Task 3: Foundation Models client + generation abstraction

**Files:**
- Create: `Yana/Services/AppleIntelligenceClient.swift`
- Test: `YanaTests/ProcessedArticleTests.swift` (create)

**Interfaces:**
- Produces:
  - `enum AppleIntelligenceAvailability: Sendable, Equatable { case available, deviceNotEligible, notEnabled, modelNotReady }`
  - `@Generable struct ProcessedArticle { var title: String; var content: String }`
  - `protocol ArticleGenerating: Sendable { var availability: AppleIntelligenceAvailability { get }; func tokenCount(_ text: String) -> Int; func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle }`
  - `struct AppleIntelligenceClient: ArticleGenerating`

- [ ] **Step 1: Write the failing test**

The framework can't run on CI, so we only assert the value type is constructible (the processor tests in Task 5 exercise behavior via a fake).

Create `YanaTests/ProcessedArticleTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct ProcessedArticleTests {
    @Test func processedArticleStoresFields() {
        let p = ProcessedArticle(title: "T", content: "<p>C</p>")
        #expect(p.title == "T")
        #expect(p.content == "<p>C</p>")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ProcessedArticleTests`
Expected: FAIL — `ProcessedArticle` is undefined.

- [ ] **Step 3: Create the client and supporting types**

Create `Yana/Services/AppleIntelligenceClient.swift`:

```swift
import Foundation
import FoundationModels

/// App-owned availability so the rest of the app never imports the framework's reason types
/// and tests can inject a value.
enum AppleIntelligenceAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible   // hardware can't run Apple Intelligence
    case notEnabled          // Apple Intelligence turned off in Settings
    case modelNotReady       // downloading / not yet ready
}

/// Guided-generation output shape. Type-safe replacement for JSON parsing on the Apple path.
@Generable
struct ProcessedArticle {
    @Guide(description: "The processed article title")
    var title: String
    @Guide(description: "The processed article body as valid HTML, preserving the input structure")
    var content: String
}

/// Abstraction over on-device generation so `AppleIntelligenceProcessor` is testable with a fake.
protocol ArticleGenerating: Sendable {
    var availability: AppleIntelligenceAvailability { get }
    /// Estimated token count, for chunk budgeting.
    func tokenCount(_ text: String) -> Int
    /// One guided-generation call. Throws on generation failure.
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle
}

/// Concrete `ArticleGenerating` backed by the on-device system language model.
struct AppleIntelligenceClient: ArticleGenerating {
    var availability: AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .modelNotReady
        }
    }

    /// Heuristic ~3.5 chars/token; overestimates tokens slightly so chunks stay within budget.
    /// (The model's exact token API is iOS 26.4+; the heuristic keeps us building on 26.0.)
    func tokenCount(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 3.5).rounded(.up)))
    }

    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, generating: ProcessedArticle.self, options: options)
        return response.content
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ProcessedArticleTests`
Expected: PASS. (If the SDK's `GenerationOptions`/`availability` labels differ from the above, adjust the client to match the live `FoundationModels` API — the protocol and `ProcessedArticle` shape are the stable contract for later tasks.)

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AppleIntelligenceClient.swift YanaTests/ProcessedArticleTests.swift
git commit -m "feat: add Foundation Models client and ArticleGenerating abstraction"
```

---

### Task 4: Block-boundary chunker

**Files:**
- Create: `Yana/Services/ArticleChunker.swift`
- Test: `YanaTests/ArticleChunkerTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks (pure; token counter injected as a closure).
- Produces: `enum ArticleChunker { static func chunk(html: String, budgetTokens: Int, tokenCount: (String) -> Int) -> [String] }`

- [ ] **Step 1: Write the failing test**

Use a deterministic token counter of 1 token per character so budgets are easy to reason about.

Create `YanaTests/ArticleChunkerTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct ArticleChunkerTests {
    // 1 token per character.
    let perChar: (String) -> Int = { $0.count }

    @Test func smallContentIsOneChunk() {
        let chunks = ArticleChunker.chunk(html: "<p>hello</p>", budgetTokens: 1000, tokenCount: perChar)
        #expect(chunks.count == 1)
        #expect(chunks[0].contains("hello"))
    }

    @Test func multipleBlocksSplitAcrossChunks() {
        // Three paragraphs, budget small enough that each ~lands in its own chunk.
        let html = "<p>aaaaaaaaaa</p><p>bbbbbbbbbb</p><p>cccccccccc</p>"
        let chunks = ArticleChunker.chunk(html: html, budgetTokens: 20, tokenCount: perChar)
        #expect(chunks.count >= 2)
        let joined = chunks.joined()
        #expect(joined.contains("aaaaaaaaaa"))
        #expect(joined.contains("cccccccccc"))
    }

    @Test func oversizedSingleBlockIsHardSplit() {
        let big = "<p>" + String(repeating: "x", count: 200) + "</p>"
        let chunks = ArticleChunker.chunk(html: big, budgetTokens: 50, tokenCount: perChar)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { perChar($0) <= 50 * 3 })  // within hard-split char bound
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleChunkerTests`
Expected: FAIL — `ArticleChunker` is undefined.

- [ ] **Step 3: Implement the chunker**

Create `Yana/Services/ArticleChunker.swift`:

```swift
import Foundation
import SwiftSoup

/// Splits article HTML into chunks whose estimated token count fits a budget, breaking on
/// top-level block boundaries so HTML elements are never cut mid-tag. A single block larger
/// than the budget is hard-split by characters as a fallback.
enum ArticleChunker {
    static func chunk(html: String, budgetTokens: Int, tokenCount: (String) -> Int) -> [String] {
        let budget = max(1, budgetTokens)

        // Top-level block elements; fall back to the whole string if parsing yields nothing.
        let blocks: [String]
        if let body = try? SwiftSoup.parse(html).body(),
           let children = try? body.children().array(),
           !children.isEmpty {
            blocks = children.compactMap { try? $0.outerHtml() }
        } else {
            blocks = [html]
        }

        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }

        for block in blocks {
            if tokenCount(block) > budget {
                // Block alone exceeds budget: flush, then hard-split this block by characters.
                flush()
                chunks.append(contentsOf: hardSplit(block, budgetTokens: budget, tokenCount: tokenCount))
                continue
            }
            let candidate = current.isEmpty ? block : current + "\n" + block
            if tokenCount(candidate) > budget {
                flush()
                current = block
            } else {
                current = candidate
            }
        }
        flush()
        return chunks.isEmpty ? [html] : chunks
    }

    /// Character-based fallback split for an oversized single block. Conservative char bound
    /// (budget * 3) keeps each piece within the token budget under the ~3.5 chars/token estimate.
    private static func hardSplit(_ s: String, budgetTokens: Int, tokenCount: (String) -> Int) -> [String] {
        let charBudget = max(1, budgetTokens * 3)
        var pieces: [String] = []
        var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: charBudget, limitedBy: s.endIndex) ?? s.endIndex
            pieces.append(String(s[index..<end]))
            index = end
        }
        return pieces
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleChunkerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleChunker.swift YanaTests/ArticleChunkerTests.swift
git commit -m "feat: add block-boundary article chunker"
```

---

### Task 5: `AppleIntelligenceProcessor` (passthrough / drop / map-reduce)

**Files:**
- Create: `Yana/Services/AppleIntelligenceProcessor.swift`
- Test: `YanaTests/AppleIntelligenceProcessorTests.swift` (create)

**Interfaces:**
- Consumes: `AIProcessing` (`Yana/Services/AIProcessor.swift:6-10`), `AggregatedArticle` (`title`/`content` are `var`), `AIOptions`, `ArticleAIText`, `ArticleChunker`, `ArticleGenerating`, `ProcessedArticle`, `AppleIntelligenceAvailability`.
- Produces: `struct AppleIntelligenceProcessor: AIProcessing` with `init(generator: ArticleGenerating, temperature: Double, maxTokens: Int)`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AppleIntelligenceProcessorTests.swift` with a fake generator:

```swift
import Testing
@testable import Yana

@MainActor
struct AppleIntelligenceProcessorTests {

    /// Fake generator: configurable availability; transforms content per a closure; can throw.
    struct FakeGenerator: ArticleGenerating {
        var availability: AppleIntelligenceAvailability = .available
        var shouldThrow = false
        var transform: @Sendable (String) -> String = { $0 }   // applied to the prompt's content

        func tokenCount(_ text: String) -> Int { text.count }   // 1 token/char

        func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
            if shouldThrow { throw NSError(domain: "test", code: 1) }
            return ProcessedArticle(title: "TITLE", content: transform(prompt))
        }
    }

    func article(_ content: String, title: String = "orig") -> AggregatedArticle {
        AggregatedArticle(title: title, identifier: "id", url: "https://e.com",
                          rawContent: content, content: content, date: .now, author: "", iconURL: nil)
    }

    let opts = AIOptions(summarize: false, improveWriting: true, translate: false, translateLanguage: "English")

    @Test func unavailableModelPassesArticlesThroughUnchanged() async {
        var gen = FakeGenerator(); gen.availability = .deviceNotEligible
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        let input = [article("<p>body</p>")]
        let out = await proc.process(input, ai: opts)
        #expect(out == input)   // unchanged, generator never called
    }

    @Test func generationFailureDropsArticle() async {
        var gen = FakeGenerator(); gen.shouldThrow = true
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        let out = await proc.process([article("<p>body</p>")], ai: opts)
        #expect(out.isEmpty)
    }

    @Test func emptyContentKeptWithoutCalling() async {
        let proc = AppleIntelligenceProcessor(generator: FakeGenerator(), temperature: 0.3, maxTokens: 2000)
        let input = [article("")]
        let out = await proc.process(input, ai: opts)
        #expect(out == input)
    }

    @Test func mapConcatenatesChunkOutputsAndTakesTitleFromFirstChunk() async {
        // Tiny budget forces multiple chunks; transform marks each processed chunk.
        var gen = FakeGenerator()
        gen.transform = { _ in "<p>X</p>" }
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 5)
        let html = "<p>aaaaaaaaaa</p><p>bbbbbbbbbb</p>"
        let out = await proc.process([article(html)], ai: opts)
        #expect(out.count == 1)
        #expect(out[0].title == "TITLE")
        #expect(out[0].content.contains("X"))
    }

    @Test func disabledOptionsReturnInputUnchanged() async {
        let proc = AppleIntelligenceProcessor(generator: FakeGenerator(), temperature: 0.3, maxTokens: 2000)
        let none = AIOptions(summarize: false, improveWriting: false, translate: false, translateLanguage: "English")
        let input = [article("<p>body</p>")]
        #expect(await proc.process(input, ai: none) == input)
    }
}
```

> Note: `AggregatedArticle`'s memberwise init is `(title:identifier:url:rawContent:content:date:author:iconURL:)` — `author` is a non-optional `String`, `iconURL` is `String?`. The helper above uses these exact labels.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppleIntelligenceProcessorTests`
Expected: FAIL — `AppleIntelligenceProcessor` is undefined.

- [ ] **Step 3: Implement the processor**

Create `Yana/Services/AppleIntelligenceProcessor.swift`:

```swift
import Foundation

/// On-device AI post-processor. Parallel to `AIProcessor` but routes through the system
/// language model with chunk + map-reduce to fit the ~4096-token window. Off-main, `Sendable`,
/// no SwiftData. Model-unavailable → passthrough; per-article failure → drop.
struct AppleIntelligenceProcessor: AIProcessing {
    let generator: ArticleGenerating
    let temperature: Double
    let maxTokens: Int

    // On-device context window and reserves for instructions + model output.
    static let contextWindowTokens = 4096
    static let outputReserveTokens = 1200
    static let instructionReserveTokens = 400
    static var contentBudgetTokens: Int {
        max(256, contextWindowTokens - outputReserveTokens - instructionReserveTokens)
    }

    init(generator: ArticleGenerating, temperature: Double, maxTokens: Int) {
        self.generator = generator
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
        let anyEnabled = ai.summarize || ai.improveWriting || ai.translate
        guard anyEnabled else { return input }
        // Model unavailable on this device → passthrough, never call the model.
        guard generator.availability == .available else { return input }

        var output: [AggregatedArticle] = []
        for article in input {
            if Task.isCancelled { break }
            guard !article.content.isEmpty else { output.append(article); continue }
            do {
                output.append(try await processOne(article, ai: ai))
            } catch {
                continue   // drop on failure
            }
        }
        return output
    }

    private func processOne(_ article: AggregatedArticle, ai: AIOptions) async throws -> AggregatedArticle {
        let clean = ArticleAIText.cap((try? ArticleAIText.stripChrome(article.content)) ?? article.content)
        let chunks = ArticleChunker.chunk(html: clean,
                                          budgetTokens: Self.contentBudgetTokens,
                                          tokenCount: generator.tokenCount)

        let instructions = Self.instructions(ai: ai)
        var title = article.title
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
        var content = mapped.joined(separator: "\n")

        // Reduce: when summarizing, fold the (already per-chunk-summarized) pieces into one.
        if ai.summarize, chunks.count > 1 {
            let reduced = try await generator.generate(
                instructions: Self.reduceInstructions,
                prompt: Self.prompt(title: title, html: ArticleAIText.cap(content)),
                temperature: temperature,
                maxTokens: maxTokens
            )
            title = reduced.title
            content = reduced.content
        }

        var updated = article
        updated.title = title
        updated.content = content
        return updated
    }

    // MARK: - Prompt assembly (guided generation: no JSON-format boilerplate needed)

    static func instructions(ai: AIOptions) -> String {
        var parts = ["You process article content provided as HTML. "
            + "Preserve all HTML tags and structure in the content you return."]
        if ai.summarize { parts.append(ArticleAIText.summarizeInstruction) }
        if ai.improveWriting { parts.append(ArticleAIText.improveWritingInstruction) }
        if ai.translate {
            parts.append(ArticleAIText.translateInstruction(language: ai.translateLanguage))
        }
        return parts.joined(separator: "\n")
    }

    static let reduceInstructions =
        "You combine several partial article summaries into one concise summary. "
        + "Preserve any HTML structure. " + ArticleAIText.summarizeInstruction

    static func prompt(title: String, html: String) -> String {
        "Title: \(title)\n\nContent (HTML):\n\(html)"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppleIntelligenceProcessorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AppleIntelligenceProcessor.swift YanaTests/AppleIntelligenceProcessorTests.swift
git commit -m "feat: add AppleIntelligenceProcessor with chunk + map-reduce"
```

---

### Task 6: Wire the processor factory into `AggregationService`

**Files:**
- Modify: `Yana/Services/AggregationService.swift:35-39` (`currentAIProcessor`)
- Test: `YanaTests/MakeAIConfigTests.swift` (create or extend if an equivalent exists)

**Interfaces:**
- Consumes: `AppleIntelligenceProcessor`, `AppleIntelligenceClient`, `AIProcessor`, `makeAIConfig`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/MakeAIConfigTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct MakeAIConfigTests {
    @Test func appleIntelligenceConfigHasNoKeyOrModel() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ai-test")!)
        settings.activeAIProvider = .appleIntelligence
        let config = AggregationService.makeAIConfig(settings: settings, loadKey: { _ in "should-not-be-read" })
        #expect(config.provider == .appleIntelligence)
        #expect(config.model.isEmpty)
        #expect(config.apiKey.isEmpty)   // keyItem is nil → loadKey never consulted
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MakeAIConfigTests`
Expected: FAIL if `activeAIProvider` setter or config behavior isn't present yet; otherwise it surfaces any missed switch arm. (Task 1 added the `.appleIntelligence` arm to `makeAIConfig`, so this should pass once that arm is in — the test pins the contract.)

- [ ] **Step 3: Select the processor by provider**

In `Yana/Services/AggregationService.swift`, replace `currentAIProcessor`:

```swift
    private func currentAIProcessor() -> AIProcessing {
        if let injectedAIProcessor { return injectedAIProcessor }
        let settings = AppSettings()
        let config = Self.makeAIConfig(settings: settings)
        if config.provider == .appleIntelligence {
            return AppleIntelligenceProcessor(
                generator: AppleIntelligenceClient(),
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )
        }
        return AIProcessor(config: config, requestDelay: settings.aiRequestDelay)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MakeAIConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/MakeAIConfigTests.swift
git commit -m "feat: route appleIntelligence provider to on-device processor"
```

---

### Task 7: Settings UI status row + localization

**Files:**
- Modify: `Yana/Views/Config/SettingsScreenView.swift:81-110` (`aiProviderSection`)
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AppleIntelligenceClient().availability`, `AppleIntelligenceAvailability`. The provider `Picker` already iterates `AIProvider.allCases`, so "Apple Intelligence" appears automatically (no change needed there).

- [ ] **Step 1: Add the availability status row**

In `Yana/Views/Config/SettingsScreenView.swift`, add a computed status string and a row shown only when Apple Intelligence is the active provider. Append inside `aiProviderSection`'s `Section`, after the Gemini `DisclosureGroup`:

```swift
            if settings.activeAIProvider == .appleIntelligence {
                LabeledContent("Status", value: appleIntelligenceStatus)
            }
```

Add this computed property to the view (near the other helpers, e.g. after `aiProviderSection`):

```swift
    private var appleIntelligenceStatus: String {
        switch AppleIntelligenceClient().availability {
        case .available:
            return String(localized: "Available")
        case .deviceNotEligible:
            return String(localized: "Not available on this device")
        case .notEnabled:
            return String(localized: "Turn on Apple Intelligence in Settings")
        case .modelNotReady:
            return String(localized: "Model downloading…")
        }
    }
```

- [ ] **Step 2: Add the four strings to the catalog (en + de)**

Open `Yana/Resources/Localizable.xcstrings` and add these keys, each with `en` and a `de` translation, both `"state" : "translated"`. The German follows Apple style (infinitive, no Du/Sie):

| Key (`en`) | `de` |
|---|---|
| `Available` | `Verfügbar` |
| `Not available on this device` | `Auf diesem Gerät nicht verfügbar` |
| `Turn on Apple Intelligence in Settings` | `Apple Intelligence in den Einstellungen aktivieren` |
| `Model downloading…` | `Modell wird geladen …` |

Example JSON shape for one entry (mirror the file's existing structure for the rest):

```json
"Available" : {
  "localizations" : {
    "de" : {
      "stringUnit" : { "state" : "translated", "value" : "Verfügbar" }
    }
  }
}
```

- [ ] **Step 3: Build to verify the view compiles and the catalog parses**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (no missing-localization warnings for the four new keys).

- [ ] **Step 4: Manual check (status row)**

Run the app, open Settings → AI Provider, select "Apple Intelligence". On the iPhone 17 simulator (no on-device model), the Status row should read "Not available on this device" or "Turn on Apple Intelligence in Settings". Confirm no key/model fields are required to use the provider.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/SettingsScreenView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat: show Apple Intelligence availability in settings"
```

---

### Task 8: Full test + build verification

**Files:** none (verification only)

- [ ] **Step 1: Run the whole suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: TEST SUCCEEDED — all new and existing tests pass.

- [ ] **Step 2: Regenerate project if any files were added outside Xcode**

Run: `xcodegen generate`
Expected: project regenerates; new `Yana/Services/*.swift` and `YanaTests/*.swift` are picked up. (Run this *before* the test step if the new files aren't in the target yet.)

- [ ] **Step 3: Final commit if regeneration changed the project**

```bash
git add Yana.xcodeproj project.yml
git commit -m "chore: regenerate project for Apple Intelligence provider"
```

---

## Self-Review

**Spec coverage:**
- New provider case → Task 1. ✓
- Shared `ArticleAIText` helpers (targeted refactor) → Task 2. ✓
- Foundation Models client (availability mapping, guided generation, token counting) → Task 3. ✓
- Chunk on block boundaries, hard-split oversized blocks → Task 4. ✓
- Processor: passthrough-when-unavailable, drop-on-failure, empty-content keep, map concat + title-from-first-chunk, summarize reduce, cancellation → Task 5. ✓
- Factory selection by provider → Task 6. ✓
- Settings status row + 4 localized strings (en/de) → Task 7. ✓
- All three tasks offered (summarize/improve/translate) → instructions builder in Task 5 + per-feed `AIOptions` unchanged. ✓
- `makeAIConfig` handles Apple (no key/model) → Task 1 + pinned in Task 6. ✓

**Deviation from spec (noted):** the spec proposed relaxing the `AIProcessor` key gate for Apple. Because the factory routes Apple to a *separate* `AppleIntelligenceProcessor`, `AIProcessor` never runs with the Apple provider, so its gate is left unchanged (avoids dead code). The Apple gate lives in `AppleIntelligenceProcessor` and has no key check.

**Placeholder scan:** no TBD/TODO; every code step has full code; two explicit "verify against the live SDK / actual initializer labels" notes (Task 3, Task 5) are confirmation steps, not placeholders.

**Type consistency:** `ArticleGenerating`, `ProcessedArticle(title:content:)`, `AppleIntelligenceAvailability` cases (`available`/`deviceNotEligible`/`notEnabled`/`modelNotReady`), `AppleIntelligenceProcessor(generator:temperature:maxTokens:)`, and `ArticleChunker.chunk(html:budgetTokens:tokenCount:)` are used identically across Tasks 3–7.
