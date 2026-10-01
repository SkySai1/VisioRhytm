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
    settings.thinking = .disabled
    settings.suggestionCount = 2
    settings.options.numPredict = 512
    settings.options.seed = 42
    settings.mode = .fullSong
    let client = OllamaClient()
    #expect(try await client.models(settings: settings).contains(settings.model))
    let text = "В ночи нам светит лунный свет\nИ мы идём навстречу"
    let target = try #require(RhymeTarget.find(in: text, selection: NSRange(location: (text as NSString).length, length: 0)))
    let messages = RhymePromptBuilder.messages(lyrics: text, target: target, settings: settings, session: .init())
    let reply = try await client.chat(messages: messages, settings: settings, format: .suggestions(2))
    let suggestions = try RhymePromptBuilder.suggestions(from: reply.message.content, target: target, count: 2)
    #expect(suggestions.count == 2)
    #expect(reply.promptEvalCount != nil)
    let compression = try await client.chat(messages: RhymePromptBuilder.compressionMessages(previousSummary: "", chunk: messages.map(\.content).joined(separator: "\n") + reply.message.content), settings: settings, format: .summary)
    #expect(!(try RhymePromptBuilder.summary(from: compression.message.content)).isEmpty)
    print("Ollama \(settings.model): \(suggestions.count) JSON suggestions; prompt=\(reply.promptEvalCount ?? 0), output=\(reply.evalCount ?? 0); JSON compression passed")
}
