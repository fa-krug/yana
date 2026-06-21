import Foundation
import Testing
@testable import Yana

@Suite("ScriptEngine")
struct ScriptEngineTests {
    /// An engine whose network bridge returns canned responses (no live network).
    private func engine(responses: [String: String] = [:]) -> ScriptEngine {
        ScriptEngine(httpGet: { url, _, _, _ in
            if let body = responses[url] { return .init(body: body, error: nil) }
            return .init(body: nil, error: "no stub for \(url)")
        })
    }

    private func input(_ url: String = "https://example.com") -> ScriptEngine.Input {
        ScriptEngine.Input(url: url, secret: "")
    }

    @Test func emitsArticleWithAllFields() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "Hello", url: "https://x.com/1", html: "<p>Body</p>",
                      author: "Ann", date: 1700000000000 });
        }
        """
        let result = try await engine().run(source: source, input: input())
        let article = try #require(result.articles.first)
        #expect(result.articles.count == 1)
        #expect(article.title == "Hello")
        #expect(article.url == "https://x.com/1")
        #expect(article.html == "<p>Body</p>")
        #expect(article.author == "Ann")
        #expect(article.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func dropsEntriesMissingTitleOrURL() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "", url: "https://x.com/1" });   // no title -> dropped
          Yana.emit({ title: "No URL" });                      // no url   -> dropped
          Yana.emit({ title: "Keep", url: "https://x.com/2" });
        }
        """
        let result = try await engine().run(source: source, input: input())
        #expect(result.articles.map(\.title) == ["Keep"])
    }

    @Test func acceptsReturnedArrayAsSugar() async throws {
        let source = """
        function run(input) {
          return [ { title: "A", url: "https://x.com/a" }, { title: "B", url: "https://x.com/b" } ];
        }
        """
        let result = try await engine().run(source: source, input: input())
        #expect(result.articles.map(\.title) == ["A", "B"])
    }

    @Test func maxArticlesStopsAfterFirstEmit() async throws {
        let source = """
        function run(input) {
          Yana.emit({ title: "First", url: "https://x.com/1" });
          Yana.emit({ title: "Second", url: "https://x.com/2" });
        }
        """
        let result = try await engine().run(source: source, input: input(), maxArticles: 1)
        #expect(result.articles.map(\.title) == ["First"])
    }

    @Test func httpGetBridgeFeedsJSONIntoEmit() async throws {
        let json = #"{"items":[{"headline":"From API","permalink":"https://api/1"}]}"#
        let source = """
        function run(input) {
          var data = JSON.parse(Yana.httpGet(input.url));
          data.items.forEach(function(p) { Yana.emit({ title: p.headline, url: p.permalink }); });
        }
        """
        let result = try await engine(responses: ["https://api.test/feed": json])
            .run(source: source, input: input("https://api.test/feed"))
        #expect(result.articles.map(\.title) == ["From API"])
        #expect(result.articles.first?.url == "https://api/1")
    }

    @Test func httpGetFailureThrowsCatchableJSError() async throws {
        let source = """
        function run(input) {
          try { Yana.httpGet("https://missing"); }
          catch (e) { Yana.emit({ title: "Recovered", url: "https://x.com/1" }); }
        }
        """
        let result = try await engine().run(source: source, input: input())
        #expect(result.articles.map(\.title) == ["Recovered"])
    }

    @Test func selectExtractsTextAndAttributes() async throws {
        let html = "<div><a class='t' href='https://x.com/p'>Title</a></div>"
        let source = """
        function run(input) {
          var nodes = Yana.select(\(jsString(html)), "a.t");
          var n = nodes[0];
          Yana.emit({ title: n.text, url: n.attr("href") });
        }
        """
        let result = try await engine().run(source: source, input: input())
        let article = try #require(result.articles.first)
        #expect(article.title == "Title")
        #expect(article.url == "https://x.com/p")
    }

    @Test func parseDateReturnsEpochMillis() async throws {
        let source = """
        function run(input) {
          var ms = Yana.parseDate("2023-11-14T22:13:20Z");
          Yana.emit({ title: "Dated", url: "https://x.com/1", date: ms });
        }
        """
        let result = try await engine().run(source: source, input: input())
        #expect(result.articles.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func logIsCaptured() async throws {
        let source = """
        function run(input) {
          Yana.log("hello", "world");
          Yana.emit({ title: "X", url: "https://x.com/1" });
        }
        """
        let result = try await engine().run(source: source, input: input())
        #expect(result.logs == ["hello world"])
    }

    @Test func secretIsExposedToScript() async throws {
        let source = """
        function run(input) { Yana.emit({ title: input.secret, url: "https://x.com/1" }); }
        """
        let result = try await engine().run(source: source,
                                            input: ScriptEngine.Input(url: "https://x", secret: "s3cr3t"))
        #expect(result.articles.first?.title == "s3cr3t")
    }

    @Test func missingRunFunctionThrows() async throws {
        await #expect(throws: ScriptError.missingEntryPoint) {
            try await engine().run(source: "var x = 1;", input: input())
        }
    }

    @Test func scriptRuntimeErrorThrows() async throws {
        await #expect(throws: ScriptError.self) {
            try await engine().run(source: "function run(input) { throw new Error('boom'); }", input: input())
        }
    }

    // Helper: encode a Swift string as a JS string literal for embedding in a script.
    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let json = String(data: data, encoding: .utf8)!   // ["..."]
        return String(json.dropFirst().dropLast())          // "..."
    }
}
