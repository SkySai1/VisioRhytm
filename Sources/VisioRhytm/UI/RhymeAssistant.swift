import Foundation
import Observation
import VisioRhytmRhyme

struct RhymePresentation: Equatable {
    var lineNumber: Int?
    var prefix: String = ""
    var suggestions: [String] = []
    var isGenerating = false
    var error: String?
    var isVisible: Bool { lineNumber != nil && (isGenerating || !suggestions.isEmpty || error != nil) }
}

@MainActor @Observable
final class RhymeAssistant {
    private(set) var settings: OllamaSettings
    private(set) var session = RhymeSession()
    private(set) var presentation = RhymePresentation()
    private(set) var isCompressing = false
    private(set) var compressionStep = 0
    private(set) var lastPromptTokens: Int?
    private(set) var lastOutputTokens: Int?
    private(set) var lastThinkingCharacters = 0
    private(set) var contextError: String?
    private(set) var editorText = ""
    private(set) var editorSelection = NSRange(location: NSNotFound, length: 0)
    @ObservationIgnored private let client: any OllamaServing
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var target: RhymeTarget?
    @ObservationIgnored private var ignoredDraft: String?
    @ObservationIgnored private var dismissedTarget: RhymeTarget?
    static let settingsKey = "VisioRhytm.OllamaSettings.v1"

    init(client: any OllamaServing = OllamaClient(), defaults: UserDefaults? = .standard, settings: OllamaSettings? = nil) {
        self.client = client; self.defaults = defaults
        if let settings { self.settings = settings }
        else if let data = defaults?.data(forKey: Self.settingsKey),
                var saved = try? JSONDecoder().decode(OllamaSettings.self, from: data),
                (try? saved.validate(requireModel: false)) != nil {
            if saved.thinking == .automatic {
                saved.thinking = .disabled
                if let migrated = try? JSONEncoder().encode(saved) { defaults?.set(migrated, forKey: Self.settingsKey) }
            }
            self.settings = saved
        }
        else { self.settings = OllamaSettings() }
    }
    var contextUsage: RhymeContextUsage {
        RhymePromptBuilder.usage(messages: RhymePromptBuilder.messages(lyrics: editorText, target: target, settings: settings, session: session), settings: settings)
    }
    var canCompress: Bool { settings.enabled && settings.mode == .fullSong && session.canCompress && !isCompressing }
    func applySettings(_ suppliedSettings: OllamaSettings) throws {
        var newSettings = suppliedSettings
        if newSettings.thinking == .automatic { newSettings.thinking = .disabled }
        try newSettings.validate(requireModel: newSettings.enabled)
        let reset = settings.serverURL != newSettings.serverURL || settings.model != newSettings.model
            || settings.mode != newSettings.mode || settings.systemPrompt != newSettings.systemPrompt
        settings = newSettings
        if let data = try? JSONEncoder().encode(newSettings) { defaults?.set(data, forKey: Self.settingsKey) }
        if reset { resetContext() }
        refresh()
    }
    func setEnabled(_ enabled: Bool) {
        // Enabling with no model opens a useful settings error rather than discarding the toggle.
        settings.enabled = enabled
        if let data = try? JSONEncoder().encode(settings) { defaults?.set(data, forKey: Self.settingsKey) }
        if enabled { refresh() } else { cancel(); presentation = .init(); target = nil }
    }
    func models(settings: OllamaSettings) async throws -> [String] { try await client.models(settings: settings) }
    func updateEditor(text: String, selection: NSRange) {
        guard text != editorText || selection != editorSelection else { return }
        if text != editorText { dismissedTarget = nil }
        editorText = text; editorSelection = selection
        if text == ignoredDraft {
            cancel(); presentation = .init()
            target = settings.enabled ? RhymeTarget.find(in: text, selection: selection) : nil
            return
        }
        ignoredDraft = nil
        schedule(immediate: false)
    }
    func refresh() { dismissedTarget = nil; ignoredDraft = nil; schedule(immediate: true) }
    private func cancel() {
        requestID = UUID(); task?.cancel(); task = nil
        isCompressing = false
    }
    func dismissSuggestions() {
        dismissedTarget = target; cancel(); presentation = .init()
    }
    func resetContext() {
        cancel(); session = .init(); presentation = .init(); contextError = nil
        lastPromptTokens = nil; lastOutputTokens = nil
        lastThinkingCharacters = 0
        target = nil; ignoredDraft = nil; dismissedTarget = nil
    }
    private func schedule(immediate: Bool) {
        cancel(); presentation = .init(); contextError = nil
        target = settings.enabled ? RhymeTarget.find(in: editorText, selection: editorSelection) : nil
        guard let target, target != dismissedTarget else { return }
        let settings = settings
        let text = editorText
        let messages = RhymePromptBuilder.messages(lyrics: text, target: target, settings: settings, session: session)
        let id = requestID
        task = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(settings.debounceMilliseconds)) }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                try settings.validate()
                let usage = RhymePromptBuilder.usage(messages: messages, settings: settings)
                guard !usage.isFull else { throw RhymeError.contextFull(usage.total, usage.capacity) }
                self.presentation = .init(lineNumber: target.lineIndex + 1, prefix: target.prefix, isGenerating: true)
                let reply = try await self.client.chat(messages: messages, settings: settings, format: .suggestions(settings.suggestionCount))
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                let suggestions = try RhymePromptBuilder.suggestions(from: reply.message.content, target: target, count: settings.suggestionCount)
                if settings.mode == .fullSong {
                    self.session.turns.append(.init(request: RhymePromptBuilder.request(target: target, lyrics: text, settings: settings), response: try RhymePromptBuilder.response(suggestions: suggestions)))
                }
                self.lastPromptTokens = reply.promptEvalCount; self.lastOutputTokens = reply.evalCount
                self.lastThinkingCharacters = reply.thinkingCharacters
                self.presentation = .init(lineNumber: target.lineIndex + 1, prefix: target.prefix, suggestions: suggestions)
            } catch is CancellationError {} catch {
                guard let self, self.requestID == id else { return }
                self.presentation = .init(lineNumber: target.lineIndex + 1, prefix: target.prefix, error: error.localizedDescription)
                self.contextError = error.localizedDescription
            }
        }
    }
    func accept(_ suffix: String, text: String, selection: NSRange) -> (range: NSRange, replacement: String)? {
        guard presentation.suggestions.contains(suffix), let target,
              RhymeTarget.find(in: text, selection: selection) == target,
              let edit = target.replacing(in: text, with: suffix) else { return nil }
        if settings.mode == .fullSong, !session.turns.isEmpty { session.turns[session.turns.count - 1].accepted = suffix }
        ignoredDraft = edit.text
        cancel(); presentation = .init()
        return (target.range, edit.replacement)
    }
    func compressContext() {
        guard canCompress else { return }
        cancel(); presentation = .init(); contextError = nil; isCompressing = true; compressionStep = 0
        let id = requestID
        let previous = session
        var settings = settings
        settings.options.temperature = 0.2
        settings.options.stop = []
        settings.thinking = .disabled
        // A concise memory has a bounded reserve, regardless of completion length settings.
        settings.options.numPredict = min(512, settings.options.numPredict)
        task = Task { [weak self] in
            do {
                guard let self else { return }
                try settings.validate()
                var remaining = previous.transcript
                var summary = ""
                repeat {
                    let base = RhymePromptBuilder.compressionMessages(previousSummary: summary, chunk: "")
                    let byteLimit = settings.options.numCtx - settings.options.numPredict - RhymePromptBuilder.estimatedTokens(base)
                    guard byteLimit > 0 else { throw RhymeError.contextFull(RhymePromptBuilder.estimatedTokens(base) + settings.options.numPredict, settings.options.numCtx) }
                    let chunk = RhymePromptBuilder.takeChunk(&remaining, byteLimit: byteLimit)
                    guard !chunk.isEmpty else { throw RhymeError.invalidResponse("Контекст слишком мал для сжатия. Увеличьте num_ctx.") }
                    self.compressionStep += 1
                    let reply = try await self.client.chat(messages: RhymePromptBuilder.compressionMessages(previousSummary: summary, chunk: chunk), settings: settings, format: .summary)
                    try Task.checkCancellation()
                    guard self.requestID == id else { return }
                    summary = try RhymePromptBuilder.summary(from: reply.message.content)
                } while !remaining.isEmpty
                var compressed = RhymeSession()
                compressed.summary = summary
                guard RhymePromptBuilder.estimatedTokens(compressed.messages) < RhymePromptBuilder.estimatedTokens(previous.messages) else {
                    throw RhymeError.invalidResponse("Сжатие не уменьшило историю. Предыдущий контекст сохранён.")
                }
                self.session = compressed; self.isCompressing = false
            } catch is CancellationError {} catch {
                guard let self, self.requestID == id else { return }
                self.isCompressing = false; self.contextError = error.localizedDescription
            }
        }
    }
}
