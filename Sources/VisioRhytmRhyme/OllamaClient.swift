import Foundation

public struct OllamaMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    public init(_ role: String, _ content: String) { self.role = role; self.content = content }
}

public struct OllamaReply: Decodable, Sendable {
    public let message: OllamaMessage
    public let done: Bool
    public let promptEvalCount: Int?
    public let evalCount: Int?
    public let doneReason: String?
    public init(content: String, promptTokens: Int? = nil, outputTokens: Int? = nil) {
        message = .init("assistant", content); done = true
        promptEvalCount = promptTokens; evalCount = outputTokens; doneReason = nil
    }
    enum CodingKeys: String, CodingKey {
        case message, done, promptEvalCount = "prompt_eval_count", evalCount = "eval_count", doneReason = "done_reason"
    }
}

public enum OllamaResponseSchema: Encodable, Sendable {
    case suggestions(Int), summary
    private enum Key: String, CodingKey { case type, properties, required, additionalProperties, suggestions, summary, items, minItems, maxItems, maxLength }
    public func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: Key.self)
        try root.encode("object", forKey: .type)
        try root.encode(false, forKey: .additionalProperties)
        var properties = root.nestedContainer(keyedBy: Key.self, forKey: .properties)
        switch self {
        case .suggestions(let count):
            try root.encode(["suggestions"], forKey: .required)
            var array = properties.nestedContainer(keyedBy: Key.self, forKey: .suggestions)
            try array.encode("array", forKey: .type)
            try array.encode(count, forKey: .minItems)
            try array.encode(count, forKey: .maxItems)
            var items = array.nestedContainer(keyedBy: Key.self, forKey: .items)
            try items.encode("string", forKey: .type)
            try items.encode(300, forKey: .maxLength)
        case .summary:
            try root.encode(["summary"], forKey: .required)
            var summary = properties.nestedContainer(keyedBy: Key.self, forKey: .summary)
            try summary.encode("string", forKey: .type)
        }
    }
}

public struct OllamaChatRequest: Encodable, Sendable {
    public let model: String
    public let messages: [OllamaMessage]
    public let stream = false
    public let format: OllamaResponseSchema
    public let options: OllamaOptions
    public let keepAlive: String
    public let think: Bool?
    public init(messages: [OllamaMessage], settings: OllamaSettings, format: OllamaResponseSchema) {
        model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.messages = messages; self.format = format
        options = settings.options; keepAlive = settings.keepAlive; think = settings.thinking.requestValue
    }
    enum CodingKeys: String, CodingKey { case model, messages, stream, format, options, keepAlive = "keep_alive", think }
}

public protocol OllamaServing: Sendable {
    func models(settings: OllamaSettings) async throws -> [String]
    func chat(messages: [OllamaMessage], settings: OllamaSettings, format: OllamaResponseSchema) async throws -> OllamaReply
}

public struct OllamaClient: OllamaServing, Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func models(settings: OllamaSettings) async throws -> [String] {
        struct Models: Decodable {
            struct Model: Decodable { let name: String; let capabilities: [String]? }
            let models: [Model]
        }
        let data = try await send(settings: settings, path: "tags", body: nil)
        do {
            let models = try JSONDecoder().decode(Models.self, from: data).models
                .filter { $0.capabilities?.contains("completion") != false }
            return Array(Set(models.map(\.name))).sorted()
        }
        catch { throw RhymeError.invalidResponse("Не удалось прочитать список моделей.") }
    }
    public func chat(messages: [OllamaMessage], settings: OllamaSettings, format: OllamaResponseSchema) async throws -> OllamaReply {
        try settings.validate()
        let body = try JSONEncoder().encode(OllamaChatRequest(messages: messages, settings: settings, format: format))
        let data = try await send(settings: settings, path: "chat", body: body)
        let reply: OllamaReply
        do { reply = try JSONDecoder().decode(OllamaReply.self, from: data) }
        catch { throw RhymeError.invalidResponse("Ожидался JSON message.content. Проверьте совместимость сервера с /api/chat.") }
        guard reply.done else { throw RhymeError.invalidResponse("Генерация не завершена.") }
        guard reply.doneReason != "length" else { throw RhymeError.invalidResponse("Достигнут Max tokens. Увеличьте лимит ответа.") }
        return reply
    }
    private func send(settings: OllamaSettings, path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: try settings.endpoint(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = body == nil ? min(15, settings.timeoutSeconds) : settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw RhymeError.connection(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw RhymeError.invalidResponse("Нет HTTP-статуса.") }
        guard data.count <= 2_000_000 else { throw RhymeError.invalidResponse("Ответ превышает 2 МБ.") }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Проверьте сервер и наличие модели."
            throw RhymeError.server(response.statusCode, String(message.prefix(1000)))
        }
        return data
    }
}
