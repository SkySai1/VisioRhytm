import Foundation
import AppKit
import SwiftUI
import Observation
import Testing
import VisioRhytmRhyme
@testable import VisioRhytm

private actor FakeOllama: OllamaServing {
    var calls: [[OllamaMessage]] = []
    var summaries = 0
    var summaryThinking: [OllamaThinking] = []
    var delay = 0
    var malformedCompression = false
    var responseContent: String?
    var thinkingCharacters = 0
    func configure(delay: Int = 0, malformedCompression: Bool = false) { self.delay = delay; self.malformedCompression = malformedCompression }
    func configureResponse(_ content: String, thinkingCharacters: Int) { responseContent = content; self.thinkingCharacters = thinkingCharacters }
    func models(settings: OllamaSettings) async throws -> [String] { ["poet"] }
    func chat(messages: [OllamaMessage], settings: OllamaSettings, format: OllamaResponseSchema) async throws -> OllamaReply {
        calls.append(messages)
        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
        switch format {
        case .suggestions:
            return .init(content: responseContent ?? "{\"suggestions\":[\"лунный свет\",\"счастливый рассвет\"]}", promptTokens: 200, outputTokens: 20, thinkingCharacters: thinkingCharacters)
        case .summary:
            summaries += 1
            summaryThinking.append(settings.thinking)
            return .init(content: malformedCompression ? "bad JSON" : "{\"summary\":\"Образы ночи и света, рифма свет/рассвет.\"}")
        }
    }
    var count: Int { calls.count }
}

@Test @MainActor func legacyAutomaticThinkingMigratesWithoutDiscardingOtherSettings() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var old = OllamaSettings()
    old.model = "qwen3.5:4b"; old.thinking = .automatic
    old.options.numCtx = 16000; old.options.numPredict = 5000
    old.systemPrompt = "Мой промпт, только JSON."
    defaults.set(try JSONEncoder().encode(old), forKey: RhymeAssistant.settingsKey)
    let restored = RhymeAssistant(client: FakeOllama(), defaults: defaults)
    old.thinking = .disabled
    #expect(restored.settings == old)
    let stored = try #require(defaults.data(forKey: RhymeAssistant.settingsKey))
    #expect(try JSONDecoder().decode(OllamaSettings.self, from: stored) == old)
    old.thinking = .enabled
    try restored.applySettings(old)
    #expect(RhymeAssistant(client: FakeOllama(), defaults: defaults).settings.thinking == .enabled)
}

@Test @MainActor func fullSongHistoryRetainsOnlyValidatedShortSuggestions() async throws {
    let client = FakeOllama()
    let raw = try JSONSerialization.data(withJSONObject: ["suggestions": ["лунный свет", String(repeating: "слишком длинное окончание ", count: 50)], "explanation": String(repeating: "анализ ", count: 1000)])
    await client.configureResponse(String(decoding: raw, as: UTF8.self), thinkingCharacters: 300)
    let assistant = configuredAssistant(client, full: true)
    let text = "Ночь дарит нам"
    assistant.updateEditor(text: text, selection: .init(location: (text as NSString).length, length: 0)); assistant.refresh()
    try await waitUntil { assistant.session.turns.count == 1 }
    #expect(assistant.presentation.suggestions == ["лунный свет"])
    #expect(assistant.session.turns[0].response == "{\"suggestions\":[\"лунный свет\"]}")
    #expect(assistant.lastThinkingCharacters == 300)
    assistant.refresh()
    try await waitUntil { assistant.session.turns.count == 2 }
    let calls = await client.calls
    #expect(!calls.last!.contains { $0.content.contains("слишком длинное") || $0.content.contains("анализ анализ") })
}

@MainActor private func configuredAssistant(_ client: FakeOllama, full: Bool = false) -> RhymeAssistant {
    var settings = OllamaSettings()
    settings.enabled = true; settings.model = "poet"; settings.debounceMilliseconds = 200
    settings.mode = full ? .fullSong : .nearbyLines
    return RhymeAssistant(client: client, defaults: nil, settings: settings)
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Test @MainActor func disabledAndPunctuatedLinesNeverReachOllama() async throws {
    let client = FakeOllama()
    let assistant = configuredAssistant(client)
    assistant.setEnabled(false)
    assistant.updateEditor(text: "Война на", selection: .init(location: 8, length: 0))
    assistant.refresh()
    try await Task.sleep(for: .milliseconds(250))
    #expect(await client.count == 0)
    assistant.updateEditor(text: "Война на.", selection: .init(location: 9, length: 0))
    assistant.setEnabled(true)
    try await Task.sleep(for: .milliseconds(250))
    #expect(await client.count == 0)
}

@Test @MainActor func staleRepliesCannotPopulateSuggestionsOrHistory() async throws {
    let client = FakeOllama()
    await client.configure(delay: 100)
    let assistant = configuredAssistant(client, full: true)
    let text = "Война на"
    assistant.updateEditor(text: text, selection: .init(location: (text as NSString).length, length: 0))
    assistant.refresh()
    try await waitUntil { assistant.presentation.isGenerating }
    assistant.updateEditor(text: text + ".", selection: .init(location: (text as NSString).length + 1, length: 0))
    try await Task.sleep(for: .milliseconds(200))
    #expect(assistant.presentation.suggestions.isEmpty)
    #expect(assistant.session.turns.isEmpty)
    #expect(!assistant.presentation.isVisible)
}

@Test @MainActor func acceptedCompletionIsExplicitAndDoesNotTriggerAnotherRequest() async throws {
    let client = FakeOllama()
    let assistant = configuredAssistant(client, full: true)
    let text = "[Verse]\nВойна на\nДругая строка"
    let caret = ("[Verse]\nВойна на" as NSString).length
    let selection = NSRange(location: caret, length: 0)
    assistant.updateEditor(text: text, selection: selection); assistant.refresh()
    try await waitUntil { !assistant.presentation.suggestions.isEmpty }
    #expect(assistant.editorText == text)
    let edit = try #require(assistant.accept("лунный свет", text: text, selection: selection))
    let updated = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    #expect(updated == "[Verse]\nВойна на лунный свет\nДругая строка")
    #expect(assistant.session.turns.last?.accepted == "лунный свет")
    assistant.updateEditor(text: updated, selection: .init(location: caret + (" лунный свет" as NSString).length, length: 0))
    try await Task.sleep(for: .milliseconds(250))
    #expect(await client.count == 1)
    #expect(!assistant.presentation.isVisible)
    assistant.refresh()
    try await waitUntil { assistant.session.turns.count == 2 }
    let calls = await client.calls
    #expect(calls.last!.contains { $0.content.contains("Автор принял окончание") })
    #expect(calls.last!.contains { $0.content.contains(updated) })
}

@Test @MainActor func compressionIsAtomicAndRetainsHistoryOnBadJSON() async throws {
    let client = FakeOllama()
    let assistant = configuredAssistant(client, full: true)
    var settings = assistant.settings
    settings.thinking = .enabled
    try assistant.applySettings(settings)
    let text = "Ночь дарит нам"
    assistant.updateEditor(text: text, selection: .init(location: (text as NSString).length, length: 0)); assistant.refresh()
    try await waitUntil { assistant.session.turns.count == 1 }
    let original = assistant.session
    await client.configure(malformedCompression: true)
    assistant.compressContext()
    try await waitUntil { !assistant.isCompressing }
    #expect(assistant.session == original)
    #expect(assistant.contextError != nil)
    await client.configure()
    assistant.compressContext()
    try await waitUntil { !assistant.isCompressing }
    #expect(assistant.session.turns.isEmpty)
    #expect(!assistant.session.summary.isEmpty)
    #expect(assistant.editorText == text)
    #expect(assistant.contextError == nil)
    #expect(await client.summaryThinking == [.disabled, .disabled])
    #expect(assistant.settings.thinking == .enabled)
    assistant.refresh()
    try await waitUntil { assistant.session.turns.count == 1 }
    let calls = await client.calls
    #expect(calls.last!.contains { $0.content.contains("Сжатая память") })
    #expect(calls.last!.contains { $0.content.contains(text) })
    assistant.resetContext()
    #expect(assistant.session.turns.isEmpty)
    #expect(assistant.session.summary.isEmpty)
}

@Test @MainActor func settingsPersistAndModelOrPromptChangesResetContext() async throws {
    let client = FakeOllama()
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let assistant = configuredAssistant(client, full: true)
    let text = "Ночь дарит нам"
    assistant.updateEditor(text: text, selection: .init(location: (text as NSString).length, length: 0)); assistant.refresh()
    try await waitUntil { assistant.session.turns.count == 1 }
    var settings = assistant.settings
    settings.systemPrompt = "Новый стиль рифм. Только JSON."
    settings.enabled = false
    try assistant.applySettings(settings)
    #expect(assistant.session.turns.isEmpty)
    #expect(!assistant.presentation.isVisible)
    let persisted = RhymeAssistant(client: client, defaults: defaults)
    try persisted.applySettings(settings)
    let restored = RhymeAssistant(client: client, defaults: defaults)
    #expect(restored.settings == settings)
    #expect(restored.session.turns.isEmpty)
}

@Test @MainActor func fullContextStopsBeforeOverflowAndCompressesHistoryInChunks() async throws {
    let client = FakeOllama()
    let assistant = configuredAssistant(client, full: true)
    let text = "Ночь дарит нам"
    assistant.updateEditor(text: text, selection: .init(location: (text as NSString).length, length: 0))
    for index in 1...20 {
        assistant.refresh()
        try await waitUntil { assistant.session.turns.count == index || assistant.contextError != nil }
        if assistant.contextError != nil { break }
    }
    #expect(assistant.contextUsage.isFull)
    let original = assistant.session
    let callsBefore = await client.count
    assistant.refresh()
    try await waitUntil { assistant.contextError != nil }
    #expect(await client.count == callsBefore)
    #expect(assistant.session == original)
    var settings = assistant.settings
    settings.options.numCtx = 4096
    try assistant.applySettings(settings)
    assistant.compressContext()
    try await waitUntil { !assistant.isCompressing }
    #expect(await client.summaries > 1)
    #expect(assistant.contextError == nil)
    #expect(!assistant.contextUsage.isFull)
    #expect(assistant.session.turns.isEmpty)
    let calls = await client.calls
    for call in calls.dropFirst(callsBefore) {
        #expect(RhymePromptBuilder.usage(messages: call, settings: settings).total <= settings.options.numCtx)
    }
}

@MainActor @Observable private final class EditorFixture { var text = "[Verse]\nНочь дарит нам\nДругая строка" }
private struct EditorHarness: View {
    @Bindable var fixture: EditorFixture
    let assistant: RhymeAssistant
    var body: some View {
        LyricsTextEditor(text: $fixture.text, assistant: assistant, presentation: assistant.presentation)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VISIORHYTM_EDITOR_TEST"] == "1"))
@MainActor func nativeEditorAcceptsCompletionWithUndoAndCaretPopover() async throws {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.finishLaunching()
    NSApplication.shared.activate(ignoringOtherApps: true)
    let client = FakeOllama()
    let assistant = configuredAssistant(client)
    let fixture = EditorFixture()
    let original = fixture.text
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: EditorHarness(fixture: fixture, assistant: assistant))
    window.contentView = host
    defer { assistant.resetContext(); window.contentView = nil; window.close() }
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    func findEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor($0) }.first
    }
    try await Task.sleep(for: .milliseconds(100))
    let editor = try #require(findEditor(host))
    let caret = ("[Verse]\nНочь дарит нам" as NSString).length
    window.makeFirstResponder(editor)
    editor.setSelectedRange(.init(location: caret, length: 0))
    assistant.updateEditor(text: editor.string, selection: editor.selectedRange()); assistant.refresh()
    try await waitUntil { !assistant.presentation.suggestions.isEmpty }
    try await Task.sleep(for: .milliseconds(100))
    let coordinator = try #require(editor.delegate as? LyricsTextEditor.Coordinator)
    coordinator.updatePopover()
    #expect(coordinator.popover.isShown)
    #expect(window.firstResponder === editor)
    let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    otherWindow.isReleasedWhenClosed = false
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindow)
    #expect(!coordinator.popover.isShown)
    otherWindow.close()
    coordinator.updatePopover()
    #expect(coordinator.popover.isShown)
    coordinator.pick("лунный свет")
    #expect(editor.string == "[Verse]\nНочь дарит нам лунный свет\nДругая строка")
    #expect(fixture.text == editor.string)
    #expect(editor.selectedRange().location == caret + (" лунный свет" as NSString).length)
    #expect(!coordinator.popover.isShown)
    #expect(editor.undoManager?.canUndo == true)
    editor.undoManager?.undo()
    try await Task.sleep(for: .milliseconds(50))
    #expect(editor.string == original)
    #expect(fixture.text == original)

    // The complete window must leave room for the editor with full context controls.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fullAssistant = configuredAssistant(client, full: true)
    let appState = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"), rhymeAssistant: fullAssistant)
    appState.lyricsDraft = original
    #expect(appState.applyLyrics())
    let mainHost = NSHostingView(rootView: MainWindow(state: appState))
    window.contentView = mainHost
    window.setContentSize(NSSize(width: 1100, height: 720))
    mainHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let mainEditor = try #require(findEditor(mainHost))
    let scroll = try #require(mainEditor.enclosingScrollView)
    #expect(scroll.frame.height >= 120)
    #expect(mainHost.bounds.contains(mainHost.convert(scroll.bounds, from: scroll)))
}
