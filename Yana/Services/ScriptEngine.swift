import Foundation
import JavaScriptCore
import SwiftSoup

/// A single article produced by a custom-script feed. Data-only: the script supplies raw
/// fields (and optionally raw HTML in `html`); `CustomScriptAggregator` feeds these through the
/// trusted aggregation pipeline, which sanitizes, localizes images, rewrites embeds, and runs AI.
struct ScriptArticle: Sendable, Equatable {
    var title: String
    var url: String
    var html: String = ""
    var date: Date = .now
    var author: String = ""
    var iconURL: String?
}

/// Result of one script run: the validated articles and any `Yana.log(...)` output.
struct ScriptRunResult: Sendable, Equatable {
    var articles: [ScriptArticle]
    var logs: [String]
}

enum ScriptError: Error, LocalizedError, Equatable {
    case missingEntryPoint            // script defines no `run` function
    case runtime(String)              // exception thrown by the script
    case timeLimitExceeded            // CPU watchdog fired

    var errorDescription: String? {
        switch self {
        case .missingEntryPoint:
            String(localized: "The script must define a run(input) function.")
        case .runtime(let message):
            String(localized: "Script error: \(message)")
        case .timeLimitExceeded:
            String(localized: "The script took too long and was stopped.")
        }
    }
}

/// Runs a user-authored, data-only JavaScript in a sandboxed JavaScriptCore context and returns
/// the articles it emits. The only capabilities exposed to a script are the `Yana.*` helpers
/// (network via `Yana.httpGet`, HTML/feed/date parsing, `Yana.emit`, `Yana.log`) — no filesystem,
/// no Keychain, no cross-feed data. CPU time is bounded by `JSContextGroupSetExecutionTimeLimit`.
///
/// `@unchecked Sendable`: the only stored state is the injected, `@Sendable` `httpGet` closure and
/// immutable config; each `run` builds a fresh `JSVirtualMachine`/`JSContext` used on one thread.
final class ScriptEngine: @unchecked Sendable {
    /// What a running script receives as its single argument.
    struct Input: Sendable {
        var url: String
        var secret: String = ""
    }

    /// Result of a bridged HTTP fetch. `error` non-nil ⇒ the JS `httpGet` call throws.
    struct HTTPResponse: Sendable {
        var body: String?
        var error: String?
    }

    /// Network bridge. Injectable so tests run with no live network.
    typealias HTTPGet = @Sendable (_ url: String, _ method: String,
                                   _ headers: [String: String], _ body: String?) async -> HTTPResponse

    private let timeLimit: TimeInterval
    private let maxLogLines: Int
    private let httpGet: HTTPGet
    /// JS execution is single-threaded per run; serialize it onto a private queue we are free to
    /// block (on the `httpGet` semaphore) without starving the Swift cooperative pool.
    private let queue = DispatchQueue(label: "com.yana.script-engine")

    init(timeLimit: TimeInterval = 12,
         maxLogLines: Int = 200,
         httpGet: @escaping HTTPGet = ScriptEngine.defaultHTTPGet) {
        self.timeLimit = timeLimit
        self.maxLogLines = maxLogLines
        self.httpGet = httpGet
    }

    /// Evaluate `source`, call its `run(input)`, and collect emitted articles. `maxArticles`
    /// stops execution after that many emits (the editor passes `1` for the Try preview);
    /// `nil` means unlimited.
    func run(source: String, input: Input, maxArticles: Int? = nil) async throws -> ScriptRunResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.runSync(source: source, input: input, maxArticles: maxArticles))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous core (runs on `queue`)

    /// Mutable per-run scratch shared with the JS bridge blocks (reference type so the
    /// `@convention(block)` closures mutate the same instance).
    private final class Collector {
        var articles: [ScriptArticle] = []
        var logs: [String] = []
        var stopped = false        // hit `maxArticles`: terminate cleanly, not an error
        var runtimeError: String?  // a real exception thrown by the script
    }

    fileprivate final class TimeoutFlag { var timedOut = false }

    private func runSync(source: String, input: Input, maxArticles: Int?) throws -> ScriptRunResult {
        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else {
            throw ScriptError.runtime("could not create a JavaScript context")
        }
        let collector = Collector()
        let timeout = TimeoutFlag()

        // CPU watchdog: terminate the script if it runs longer than `timeLimit` seconds of CPU.
        // Network waits happen in native code and do not count against this budget.
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        JSContextGroupSetExecutionTimeLimit(group, timeLimit, scriptTimeLimitCallback,
                                            Unmanaged.passUnretained(timeout).toOpaque())

        context.exceptionHandler = { _, exception in
            guard let message = exception?.toString() else { return }
            if message.contains(Self.stopSentinel) { return }   // intentional `maxArticles` stop
            collector.runtimeError = message
        }

        installBridge(into: context, collector: collector, maxArticles: maxArticles)

        // Evaluate the user source and the small ergonomic prelude.
        context.evaluateScript(Self.prelude)
        context.evaluateScript(source)
        if let error = collector.runtimeError { throw ScriptError.runtime(error) }

        guard let runFn = context.objectForKeyedSubscript("run"),
              !runFn.isUndefined, !runFn.isNull else {
            throw ScriptError.missingEntryPoint
        }

        let inputValue = JSValue(object: ["url": input.url, "secret": input.secret], in: context)
        let returnValue = runFn.call(withArguments: [inputValue as Any])

        if timeout.timedOut { throw ScriptError.timeLimitExceeded }
        if !collector.stopped, let error = collector.runtimeError { throw ScriptError.runtime(error) }

        // Sugar: a script may `return` an array instead of using `Yana.emit`.
        if collector.articles.isEmpty, !collector.stopped,
           let returnValue, returnValue.isArray {
            appendArray(returnValue, into: collector, maxArticles: maxArticles)
        }

        return ScriptRunResult(articles: collector.articles, logs: collector.logs)
    }

    // MARK: - `Yana.*` bridge

    private func installBridge(into context: JSContext, collector: Collector, maxArticles: Int?) {
        guard let yana = JSValue(newObjectIn: context) else { return }
        let maxLogLines = self.maxLogLines
        let httpGet = self.httpGet

        // Yana.emit(article)
        let emit: @convention(block) (JSValue) -> Void = { [weak context] obj in
            guard let context, !collector.stopped else { return }
            if let article = Self.mapArticle(obj) { collector.articles.append(article) }
            if let max = maxArticles, collector.articles.count >= max {
                collector.stopped = true
                context.exception = JSValue(newErrorFromMessage: Self.stopSentinel, in: context)
            }
        }
        yana.setObject(emit, forKeyedSubscript: "emit" as NSString)

        // Yana.log(...)
        let log: @convention(block) () -> Void = {
            guard collector.logs.count < maxLogLines else { return }
            let args = (JSContext.currentArguments() as? [JSValue]) ?? []
            collector.logs.append(args.map { $0.toString() ?? "" }.joined(separator: " "))
        }
        yana.setObject(log, forKeyedSubscript: "log" as NSString)

        // Yana.httpGet(url, options?) -> string (throws a JS error on failure)
        let http: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak context] urlValue, options in
            guard let context else { return nil }
            let url = urlValue.toString() ?? ""
            var method = "GET"
            var headers: [String: String] = [:]
            var body: String?
            if options.isObject {
                if let m = options.objectForKeyedSubscript("method"), m.isString { method = m.toString() ?? "GET" }
                if let h = options.objectForKeyedSubscript("headers"), h.isObject,
                   let dict = h.toDictionary() as? [String: Any] {
                    for (k, v) in dict { headers[k] = "\(v)" }
                }
                if let b = options.objectForKeyedSubscript("body"), b.isString { body = b.toString() }
            }
            // Bridge async → sync: block this (private, non-cooperative) thread on the fetch.
            let semaphore = DispatchSemaphore(value: 0)
            let resultBox = ResponseBox()
            Task {
                resultBox.response = await httpGet(url, method, headers, body)
                semaphore.signal()
            }
            semaphore.wait()
            if let error = resultBox.response.error {
                context.exception = JSValue(newErrorFromMessage: error, in: context)
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: resultBox.response.body ?? "", in: context)
        }
        yana.setObject(http, forKeyedSubscript: "httpGet" as NSString)

        // Yana.selectNative(html, css) -> [{ text, html, attrs }]  (wrapped by the prelude)
        let select: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak context] htmlValue, cssValue in
            guard let context else { return nil }
            do {
                let doc = try HTMLUtils.parse(htmlValue.toString() ?? "")
                let nodes: [[String: Any]] = try doc.select(cssValue.toString() ?? "").array().map { element in
                    var attrs: [String: String] = [:]
                    if let list = element.getAttributes()?.asList() {
                        for attribute in list { attrs[attribute.getKey()] = attribute.getValue() }
                    }
                    return ["text": try element.text(), "html": try element.html(), "attrs": attrs]
                }
                return JSValue(object: nodes, in: context)
            } catch {
                context.exception = JSValue(newErrorFromMessage: "select failed: \(error)", in: context)
                return JSValue(undefinedIn: context)
            }
        }
        yana.setObject(select, forKeyedSubscript: "selectNative" as NSString)

        // Yana.parseFeed(xml) -> [{ title, link, content, author, date }]
        let parseFeed: @convention(block) (JSValue) -> JSValue? = { [weak context] xmlValue in
            guard let context else { return nil }
            guard let data = (xmlValue.toString() ?? "").data(using: .utf8) else {
                return JSValue(object: [Any](), in: context)
            }
            do {
                let entries = try FeedParser.parse(data).entries.map { entry -> [String: Any] in
                    [
                        "title": entry.title,
                        "link": entry.link,
                        "content": entry.content ?? entry.summary ?? entry.entryDescription ?? "",
                        "author": entry.author,
                        "date": entry.published.map { $0.timeIntervalSince1970 * 1000 } as Any,
                    ]
                }
                return JSValue(object: entries, in: context)
            } catch {
                context.exception = JSValue(newErrorFromMessage: "parseFeed failed: \(error)", in: context)
                return JSValue(undefinedIn: context)
            }
        }
        yana.setObject(parseFeed, forKeyedSubscript: "parseFeed" as NSString)

        // Yana.parseDate(string) -> epoch-millis number | null
        let parseDate: @convention(block) (JSValue) -> JSValue? = { [weak context] value in
            guard let context else { return nil }
            if let date = FeedParser.parseDate(value.toString()) {
                return JSValue(double: date.timeIntervalSince1970 * 1000, in: context)
            }
            return JSValue(nullIn: context)
        }
        yana.setObject(parseDate, forKeyedSubscript: "parseDate" as NSString)

        context.setObject(yana, forKeyedSubscript: "Yana" as NSString)
    }

    /// Holds the bridged response across the semaphore wait (reference type the `Task` mutates).
    private final class ResponseBox: @unchecked Sendable {
        var response = HTTPResponse(body: nil, error: "cancelled")
    }

    // MARK: - Mapping

    /// Map a JS article object to a `ScriptArticle`, dropping entries without a title and url.
    static func mapArticle(_ object: JSValue) -> ScriptArticle? {
        guard object.isObject else { return nil }
        func string(_ key: String) -> String {
            guard let value = object.objectForKeyedSubscript(key),
                  !value.isUndefined, !value.isNull else { return "" }
            return value.toString() ?? ""
        }
        let title = string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = string("url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !url.isEmpty else { return nil }

        var date = Date.now
        if let dateValue = object.objectForKeyedSubscript("date"), !dateValue.isUndefined, !dateValue.isNull {
            if dateValue.isNumber {
                date = Date(timeIntervalSince1970: dateValue.toDouble() / 1000)
            } else if dateValue.isDate, let parsed = dateValue.toDate() {
                date = parsed
            } else if dateValue.isString, let parsed = FeedParser.parseDate(dateValue.toString()) {
                date = parsed
            }
        }

        let icon = string("iconURL")
        return ScriptArticle(title: title, url: url, html: string("html"),
                             date: date, author: string("author"),
                             iconURL: icon.isEmpty ? nil : icon)
    }

    private func appendArray(_ array: JSValue, into collector: Collector, maxArticles: Int?) {
        let count = Int(array.objectForKeyedSubscript("length")?.toInt32() ?? 0)
        for index in 0..<count {
            if let max = maxArticles, collector.articles.count >= max { break }
            if let element = array.atIndex(index), let article = Self.mapArticle(element) {
                collector.articles.append(article)
            }
        }
    }

    // MARK: - Constants

    /// Sentinel message thrown to unwind the script once `maxArticles` is reached. Recognized by
    /// the exception handler so the clean stop is not reported as a script error.
    static let stopSentinel = "__YANA_SCRIPT_STOP__"

    /// Ergonomic JS wrappers layered over the native bridge.
    private static let prelude = """
    Yana.select = function(html, css) {
      var nodes = Yana.selectNative(html, css) || [];
      for (var i = 0; i < nodes.length; i++) {
        (function(node) {
          node.attr = function(name) { return node.attrs ? node.attrs[name] : undefined; };
        })(nodes[i]);
      }
      return nodes;
    };
    """

    // MARK: - Default network bridge

    /// Production `httpGet`: routes through `HTTPClient` (bot UA, 25 MB cap, retry/backoff).
    static let defaultHTTPGet: HTTPGet = { url, method, headers, body in
        guard let parsed = URL(string: url) else {
            return HTTPResponse(body: nil, error: "invalid URL: \(url)")
        }
        var request = URLRequest(url: parsed, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = body.data(using: .utf8) }
        do {
            let data = try await HTTPClient.fetchJSON(request)
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            return HTTPResponse(body: text, error: nil)
        } catch let error as AggregatorError {
            return HTTPResponse(body: nil, error: error.errorDescription ?? "fetch failed")
        } catch {
            return HTTPResponse(body: nil, error: error.localizedDescription)
        }
    }
}

/// C callback for `JSContextGroupSetExecutionTimeLimit`. Marks the flag and terminates the script.
private let scriptTimeLimitCallback: JSShouldTerminateCallback = { _, userData in
    if let userData {
        Unmanaged<ScriptEngine.TimeoutFlag>.fromOpaque(userData).takeUnretainedValue().timedOut = true
    }
    return true   // terminate execution
}
