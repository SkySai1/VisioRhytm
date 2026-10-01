import Foundation
import Testing
@testable import VisioRhytmRhyme

private func endSelection(_ text: String) -> NSRange { NSRange(location: (text as NSString).length, length: 0) }

@Test(arguments: [".", ",", "-", "—", "–", ":", ";", "!", "?", "…", ")", "]", "\"", "»", "/", "❤️"])
func punctuationAtLineEndDisablesCompletion(ending: String) {
    let text = "Война на фронте\(ending)   "
    #expect(RhymeTarget.find(in: text, selection: endSelection(text)) == nil)
}

@Test func blankAnnotationSelectionAndMidLineAreNotCompletionTargets() {
    for text in ["", "   ", "[Припев]", "(тишина)", "[Куплет\nскрытый текст\n]", "строка\n"] {
        #expect(RhymeTarget.find(in: text, selection: endSelection(text)) == nil)
    }
    #expect(RhymeTarget.find(in: "Слова строки", selection: NSRange(location: 4, length: 0)) == nil)
    #expect(RhymeTarget.find(in: "Слова строки", selection: NSRange(location: 5, length: 6)) == nil)
    #expect(RhymeTarget.find(in: "Слова строки", selection: NSRange(location: NSNotFound, length: 0)) == nil)
    let comment = "[Куплет\nвнутри комментария\n]\nВойна на фронте"
    #expect(RhymeTarget.find(in: comment, selection: NSRange(location: ("[Куплет\nвнутри комментария" as NSString).length, length: 0)) == nil)
}

@Test(arguments: ["\n", "\r\n", "\r", "\u{2028}"])
func unicodeCompletionPreservesIndentationAndOtherLines(newline: String) throws {
    let line = "  Над нами 🌙 сияет   "
    let text = "[Verse]\(newline)\(line)\(newline)Другая строка"
    let caret = ("[Verse]\(newline)\(line)" as NSString).length
    let target = try #require(RhymeTarget.find(in: text, selection: NSRange(location: caret, length: 0)))
    #expect(target.lineIndex == 1)
    let edit = try #require(target.replacing(in: text, with: "лунный свет."))
    #expect(edit.text == "[Verse]\(newline)  Над нами 🌙 сияет лунный свет.\(newline)Другая строка")
    #expect(edit.selection.location == ("[Verse]\(newline)  Над нами 🌙 сияет лунный свет." as NSString).length)
    #expect(target.replacing(in: "Изменённый текст", with: "свет") == nil)
}

@Test func neighbouringContextIsBoundedAndFullSongContainsAllGenerations() throws {
    let text = "До ноль\nДо один\nНачало строки\nПосле один\nПосле два"
    let caret = ("До ноль\nДо один\nНачало строки" as NSString).length
    let target = try #require(RhymeTarget.find(in: text, selection: NSRange(location: caret, length: 0)))
    var settings = OllamaSettings()
    settings.linesBefore = 1; settings.linesAfter = 1
    var session = RhymeSession()
    session.turns.append(.init(request: "Предыдущий запрос", response: "{\"suggestions\":[\"ночь\"]}"))
    let local = RhymePromptBuilder.messages(lyrics: text, target: target, settings: settings, session: session)
    #expect(local.count == 2)
    #expect(local.last!.content.contains("До один"))
    #expect(local.last!.content.contains("После один"))
    #expect(!local.last!.content.contains("До ноль"))
    #expect(!local.last!.content.contains("После два"))
    settings.mode = .fullSong
    let full = RhymePromptBuilder.messages(lyrics: text, target: target, settings: settings, session: session)
    #expect(full[1].content.contains(text))
    #expect(full.contains { $0.content == "Предыдущий запрос" })
    #expect(full.contains { $0.content == "{\"suggestions\":[\"ночь\"]}" })
    #expect(full.first?.content == settings.systemPrompt)
}

@Test func jsonAnswersAreValidatedAndFullLineEchoIsRemoved() throws {
    let text = "Война на"
    let target = try #require(RhymeTarget.find(in: text, selection: endSelection(text)))
    let result = try RhymePromptBuilder.suggestions(from: """
    {"suggestions":["Война на фронте", "  фронте  ", "просторе", "...", "два\\nслова"]}
    """, target: target, count: 3)
    #expect(result == ["фронте", "просторе"])
    let shortTarget = try #require(RhymeTarget.find(in: "Я", selection: endSelection("Я")))
    #expect(try RhymePromptBuilder.suggestions(from: "{\"suggestions\":[\"Яркий свет\",\"Я ищу рассвет\"]}",
        target: shortTarget, count: 2) == ["Яркий свет", "ищу рассвет"])
    for invalid in ["Текст вместо JSON", "```json\n{\"suggestions\":[\"ночь\"]}\n```", "{\"suggestions\":[]}", "{\"summary\":\"память\"}"] {
        #expect(throws: RhymeError.self) { try RhymePromptBuilder.suggestions(from: invalid, target: target, count: 3) }
    }
    #expect(try RhymePromptBuilder.summary(from: "{\"summary\":\" рифма и образы \"}") == "рифма и образы")
    #expect(throws: RhymeError.self) { try RhymePromptBuilder.summary(from: "{\"summary\":\" \"}") }
}

@Test func settingsUseOfficialOptionNamesAndPersistCustomPrompt() throws {
    var settings = OllamaSettings()
    settings.model = "test-model"
    settings.systemPrompt = "Подбирай ироничные рифмы, только JSON."
    try settings.validate()
    let request = OllamaChatRequest(messages: [.init("user", "строка")], settings: settings, format: .suggestions(3))
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    let options = try #require(object["options"] as? [String: Any])
    #expect(options["num_ctx"] as? Int == 8192)
    #expect(options["num_predict"] as? Int == 256)
    #expect(options["top_k"] as? Int == 40)
    #expect(object["stream"] as? Bool == false)
    #expect(object["think"] as? Bool == false)
    let schema = try #require(object["format"] as? [String: Any])
    #expect(schema["required"] as? [String] == ["suggestions"])
    #expect(try JSONDecoder().decode(OllamaSettings.self, from: JSONEncoder().encode(settings)) == settings)
    settings.options.numPredict = settings.options.numCtx
    #expect(throws: RhymeError.self) { try settings.validate() }
    settings.options.numPredict = 512; settings.options.topP = .nan
    #expect(throws: RhymeError.self) { try settings.validate() }
}

@Test(arguments: [1, 3, 10], [RhymeContextMode.nearbyLines, .fullSong])
func highSavedTokenLimitCannotExpandRhymeResponse(count: Int, mode: RhymeContextMode) throws {
    var settings = OllamaSettings()
    settings.options.numCtx = 16000; settings.options.numPredict = 5000
    settings.suggestionCount = count; settings.mode = mode; settings.model = "poet"
    // Old installations saved automatic, which must no longer inherit Qwen's thinking default.
    settings.thinking = .automatic
    let request = OllamaChatRequest(messages: [], settings: settings, format: .suggestions(count))
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(json["think"] as? Bool == false)
    #expect(request.options.numPredict == 64 + count * 64)
    #expect(request.options.numPredict <= 704)
    let usage = RhymePromptBuilder.usage(messages: [], settings: settings)
    #expect(usage.reservedOutput == request.options.numPredict)
    #expect(settings.options.numPredict == 5000)
    settings.thinking = .enabled
    let explicit = OllamaChatRequest(messages: [], settings: settings, format: .suggestions(count))
    #expect(explicit.think == true)
    #expect(explicit.options.numPredict == request.options.numPredict)
    settings.options.numPredict = 64
    #expect(OllamaChatRequest(messages: [], settings: settings, format: .suggestions(count)).options.numPredict == 64)
    #expect(OllamaChatRequest(messages: [], settings: settings, format: .summary).options.numPredict == 64)
}

@Test func oversizedEndingsAndSummariesAreRejectedWithoutTruncatingWords() throws {
    let text = "Я ищу"
    let target = try #require(RhymeTarget.find(in: text, selection: endSelection(text)))
    let answer = try RhymePromptBuilder.response(suggestions: [String(repeating: "слово ", count: 30),
        "один два три четыре пять шесть семь восемь девять", "ночной рассвет"])
    #expect(try RhymePromptBuilder.suggestions(from: answer, target: target, count: 3) == ["ночной рассвет"])
    let summary = String(repeating: "память ", count: 300)
    let data = try JSONSerialization.data(withJSONObject: ["summary": summary])
    #expect(throws: RhymeError.self) { try RhymePromptBuilder.summary(from: String(decoding: data, as: UTF8.self)) }
}

@Test func contextBudgetAndChunkingNeverDropUnicodeText() {
    var text = String(repeating: "Привет 🌙 e\u{301} \n", count: 100)
    let original = text
    var chunks: [String] = []
    while !text.isEmpty {
        let chunk = RhymePromptBuilder.takeChunk(&text, byteLimit: 80)
        #expect(!chunk.isEmpty)
        #expect(chunk.utf8.count <= 80)
        chunks.append(chunk)
    }
    #expect(chunks.joined() == original)
    var settings = OllamaSettings()
    settings.options.numCtx = 1024
    let usage = RhymePromptBuilder.usage(messages: [.init("user", original)], settings: settings)
    #expect(usage.isFull)
    #expect(usage.fraction == 1)
    #expect(usage.total == usage.estimatedInput + usage.reservedOutput)
}
