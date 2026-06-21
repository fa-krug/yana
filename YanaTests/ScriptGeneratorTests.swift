import Foundation
import Testing
@testable import Yana

@Suite("ScriptGenerator")
struct ScriptGeneratorTests {
    /// Returns canned scripts in order; records how many times it was asked.
    actor FakeTextGenerator: ScriptTextGenerating {
        private(set) var calls = 0
        private let scripts: [String]
        init(_ scripts: [String]) { self.scripts = scripts }
        func generate(instructions: String, prompt: String) async throws -> String {
            defer { calls += 1 }
            return scripts[min(calls, scripts.count - 1)]
        }
    }

    private let pageStub: ScriptEngine.HTTPGet = { _, _, _, _ in
        .init(body: "<html><body><a class='t' href='https://x/1'>Title</a></body></html>", error: nil)
    }

    private func generator(_ fake: FakeTextGenerator, maxSelfHeal: Int = 2) -> ScriptGenerator {
        ScriptGenerator(textGenerator: fake,
                        engine: ScriptEngine(httpGet: pageStub),
                        httpGet: pageStub,
                        maxSelfHeal: maxSelfHeal)
    }

    @Test func succeedsOnFirstWorkingScript() async throws {
        let working = "function run(input){ Yana.emit({title:'T', url:'https://x/1', html:'<p>b</p>'}); }"
        let fake = FakeTextGenerator([working])
        let result = try await generator(fake).generate(brief: "collect posts", seedURL: "https://x")
        #expect(result.error == nil)
        #expect(result.preview?.articles.count == 1)
        #expect(result.source.contains("Yana.emit"))
        #expect(await fake.calls == 1)
    }

    @Test func selfHealsWhenFirstScriptEmitsNothing() async throws {
        let broken = "function run(input){ /* emits nothing */ }"
        let working = "function run(input){ Yana.emit({title:'T', url:'https://x/1', html:'<p>b</p>'}); }"
        let fake = FakeTextGenerator([broken, working])
        let result = try await generator(fake).generate(brief: "collect posts", seedURL: "https://x")
        #expect(result.error == nil)
        #expect(result.preview?.articles.count == 1)
        #expect(await fake.calls == 2)   // healed once
    }

    @Test func reportsErrorWhenNeverEmits() async throws {
        let broken = "function run(input){ }"
        let fake = FakeTextGenerator([broken])
        let result = try await generator(fake, maxSelfHeal: 1).generate(brief: "x", seedURL: "https://x")
        #expect(result.error != nil)
        #expect(result.preview?.articles.isEmpty ?? true)
        #expect(await fake.calls == 2)   // initial + 1 heal
    }

    @Test func extractCodeStripsMarkdownFences() {
        #expect(ScriptGenerator.extractCode("```javascript\nfunction run(){}\n```") == "function run(){}")
        #expect(ScriptGenerator.extractCode("function run(){}") == "function run(){}")
    }

    @Test func buildPromptIncludesContext() {
        let prompt = ScriptGenerator.buildPrompt(brief: "my brief", seedURL: "https://seed",
                                                 seedSample: "SEED-SAMPLE", detailSample: "DETAIL-SAMPLE",
                                                 priorSource: "old()", priorError: "boom")
        #expect(prompt.contains("https://seed"))
        #expect(prompt.contains("my brief"))
        #expect(prompt.contains("SEED-SAMPLE"))
        #expect(prompt.contains("DETAIL-SAMPLE"))
        #expect(prompt.contains("boom"))
    }

    @MainActor
    @Test func makeTextGeneratorReturnsNilWhenAIDisabled() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "script-gen-test-\(UUID().uuidString)")!)
        #expect(ScriptGenerator.makeTextGenerator(settings: settings) == nil)   // provider defaults to .none
    }
}
