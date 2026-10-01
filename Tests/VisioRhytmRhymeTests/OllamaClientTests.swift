import Foundation
import Testing
@testable import VisioRhytmRhyme

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status: Int
        let content: String
        switch url.host {
        case "models.test":
            status = 200
            content = """
            {"models":[{"name":"poet","capabilities":["completion"]},{"name":"embed","capabilities":["embedding"]},{"name":"old"},{"name":"poet"}]}
            """
        case "missing.test": status = 404; content = "{\"error\":\"model not found\"}"
        case "broken.test": status = 200; content = "not JSON"
        case "thinking.test":
            status = 200
            content = """
            {"message":{"role":"assistant","content":"","thinking":"Нужно тщательно разобрать смысл и рифмы"},"done":true,"done_reason":"length","prompt_eval_count":320,"eval_count":256}
            """
        default:
            status = 200
            content = """
            {"message":{"role":"assistant","content":"{\\"suggestions\\":[\\"лунный свет\\"]}"},"done":true,"prompt_eval_count":50,"eval_count":12}
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func reasoningExhaustionExplainsThinkingInsteadOfSuggestingLargerResponses() async throws {
    var settings = OllamaSettings()
    settings.model = "poet"; settings.serverURL = "http://thinking.test"
    do {
        _ = try await stubClient().chat(messages: [], settings: settings, format: .suggestions(3))
        Issue.record("An exhausted reasoning-only reply must be rejected")
    } catch {
        #expect(error.localizedDescription.contains("256"))
        #expect(error.localizedDescription.contains("Выключите Thinking"))
        #expect(!error.localizedDescription.contains("Увеличьте"))
    }
}

private func stubClient() -> OllamaClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return OllamaClient(session: URLSession(configuration: configuration))
}

@Test func clientFiltersEmbeddingModelsAndReadsTokenCounters() async throws {
    let client = stubClient()
    var settings = OllamaSettings()
    settings.serverURL = "http://models.test"; settings.model = "poet"
    #expect(try await client.models(settings: settings) == ["old", "poet"])
    settings.serverURL = "http://chat.test"
    let reply = try await client.chat(messages: [.init("user", "рифма")], settings: settings, format: .suggestions(1))
    #expect(reply.promptEvalCount == 50)
    #expect(reply.evalCount == 12)
    #expect(reply.message.content == "{\"suggestions\":[\"лунный свет\"]}")
}

@Test func clientReportsModelErrorsAndMalformedResponses() async {
    let client = stubClient()
    var settings = OllamaSettings(); settings.model = "poet"
    settings.serverURL = "http://missing.test"
    await #expect(throws: RhymeError.server(404, "model not found")) {
        try await client.chat(messages: [], settings: settings, format: .suggestions(1))
    }
    settings.serverURL = "http://broken.test"
    await #expect(throws: RhymeError.self) { try await client.chat(messages: [], settings: settings, format: .suggestions(1)) }
}

@Test func endpointsRejectCredentialsAndPreserveProxyPaths() throws {
    var settings = OllamaSettings()
    settings.serverURL = "http://localhost:11434/"
    #expect(try settings.endpoint("chat").absoluteString == "http://localhost:11434/api/chat")
    settings.serverURL = "https://host.test/ollama/"
    #expect(try settings.endpoint("tags").absoluteString == "https://host.test/ollama/api/tags")
    for invalid in ["file:///tmp", "http://user:password@host.test", "https://host.test?secret=x", "invalid"] {
        settings.serverURL = invalid
        #expect(throws: RhymeError.self) { try settings.endpoint("chat") }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VISIORHYTM_OLLAMA_TEST"] == "1"))
func liveOllamaReturnsRhymeAndCompressedMemoryAsJSON() async throws {
    var settings = OllamaSettings()
    settings.model = ProcessInfo.processInfo.environment["VISIORHYTM_OLLAMA_MODEL"] ?? "qwen3.5:4b"
    settings.suggestionCount = 3
    // Reproduce the saved settings behind the bug, without overriding Thinking in the test.
    settings.thinking = .automatic
    settings.options.numCtx = 16000
    settings.options.numPredict = 5000
    settings.options.seed = 42
    let client = OllamaClient()
    #expect(try await client.models(settings: settings).contains(settings.model))
    let text = "Война на невидимом фронте\nГде враг растворяется в сети\nМы строим защиту сегодня\nЧтоб завтра систему"
    let target = try #require(RhymeTarget.find(in: text, selection: NSRange(location: (text as NSString).length, length: 0)))
    var session = RhymeSession()
    for mode in [RhymeContextMode.nearbyLines, .fullSong] {
        settings.mode = mode
        // Two requests in full mode exercise the actual history sent back to the model.
        for index in 1...(mode == .fullSong ? 2 : 1) {
            let messages = RhymePromptBuilder.messages(lyrics: text, target: target, settings: settings, session: session)
            let reply = try await client.chat(messages: messages, settings: settings, format: .suggestions(3))
            let suggestions = try RhymePromptBuilder.suggestions(from: reply.message.content, target: target, count: 3)
            #expect(suggestions.count == 3)
            #expect(reply.promptEvalCount != nil)
            #expect(try #require(reply.evalCount) <= 256)
            #expect(reply.thinkingCharacters == 0)
            if mode == .fullSong {
                session.turns.append(.init(request: RhymePromptBuilder.request(target: target, lyrics: text, settings: settings),
                    response: try RhymePromptBuilder.response(suggestions: suggestions)))
            }
            print("Ollama \(settings.model) \(mode) #\(index): prompt=\(reply.promptEvalCount ?? 0), generated=\(reply.evalCount ?? 0), thinkingCharacters=\(reply.thinkingCharacters), JSON suggestions=\(suggestions.count)")
        }
    }
    let compression = try await client.chat(messages: RhymePromptBuilder.compressionMessages(previousSummary: "", chunk: session.transcript), settings: settings, format: .summary)
    #expect(!(try RhymePromptBuilder.summary(from: compression.message.content)).isEmpty)
    #expect(try #require(compression.evalCount) <= 512)
    #expect(compression.thinkingCharacters == 0)
    print("Ollama JSON compression: generated=\(compression.evalCount ?? 0), thinkingCharacters=\(compression.thinkingCharacters)")
}
