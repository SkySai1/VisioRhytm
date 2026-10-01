import SwiftUI
import VisioRhytmRhyme

struct RhymeSettingsView: View {
    let assistant: RhymeAssistant
    @State private var draft: OllamaSettings
    @State private var models: [String] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var validationError: String?
    @State private var stopText: String
    init(assistant: RhymeAssistant) {
        self.assistant = assistant
        _draft = State(initialValue: assistant.settings)
        _stopText = State(initialValue: assistant.settings.options.stop.joined(separator: "\n"))
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Ollama") {
                    TextField("Адрес сервера", text: $draft.serverURL)
                    TextField("Модель", text: $draft.model)
                    if !models.isEmpty {
                        Picker("Установленные модели", selection: $draft.model) {
                            Text("Выберите модель").tag("")
                            if !draft.model.isEmpty && !models.contains(draft.model) { Text(draft.model).tag(draft.model) }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        Button("Проверить и загрузить список моделей") { loadModels() }.disabled(isLoading)
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                    if let message { Text(message).font(.caption).textSelection(.enabled) }
                    Text("Выберите установленную текстовую модель. Приложение не скачивает модели.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Предложения") {
                    Stepper("Количество: \(draft.suggestionCount)", value: $draft.suggestionCount, in: 1...10)
                    Stepper("Строк до: \(draft.linesBefore)", value: $draft.linesBefore, in: 0...50)
                    Stepper("Строк после: \(draft.linesAfter)", value: $draft.linesAfter, in: 0...50)
                    Picker("Анализ", selection: $draft.mode) {
                        Text("Соседние строки").tag(RhymeContextMode.nearbyLines)
                        Text("Полная песня и история").tag(RhymeContextMode.fullSong)
                    }
                    numberField("Пауза перед запросом, мс", value: $draft.debounceMilliseconds)
                    Text("Подсказка появляется в конце строки без завершающей пунктуации.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Системный промпт") {
                    TextEditor(text: $draft.systemPrompt).font(.body).frame(height: 150)
                        .accessibilityLabel("Системный промпт помощника рифмы")
                    Button("Вернуть промпт по умолчанию") { draft.systemPrompt = OllamaSettings.defaultSystemPrompt }
                    Text("Ответы запрашиваются по JSON-схеме: suggestions для окончаний, summary для сжатия.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Контекст и генерация") {
                    numberField("Контекстное окно · num_ctx", value: $draft.options.numCtx)
                    numberField("Max tokens · num_predict", value: $draft.options.numPredict)
                    decimalField("temperature", value: $draft.options.temperature)
                    numberField("top_k", value: $draft.options.topK)
                    decimalField("top_p", value: $draft.options.topP)
                    decimalField("min_p", value: $draft.options.minP)
                    decimalField("repeat_penalty", value: $draft.options.repeatPenalty)
                    numberField("repeat_last_n", value: $draft.options.repeatLastN)
                    numberField("seed (-1 — случайный)", value: $draft.options.seed)
                    Picker("Thinking", selection: $draft.thinking) {
                        Text("По умолчанию модели").tag(OllamaThinking.automatic)
                        Text("Включён").tag(OllamaThinking.enabled)
                        Text("Выключен").tag(OllamaThinking.disabled)
                    }
                    Text("Для быстрых подсказок у reasoning-моделей можно выключить Thinking.").font(.caption).foregroundStyle(.secondary)
                    TextField("keep_alive", text: $draft.keepAlive)
                    decimalField("Таймаут, секунды", value: $draft.timeoutSeconds)
                    Text("Stop: одна последовательность на строку").font(.caption)
                    TextEditor(text: $stopText).font(.system(.body, design: .monospaced)).frame(height: 60)
                    Text("Лимит num_ctx зависит также от модели и памяти Ollama. Полоса контекста использует консервативную оценку; точные счётчики последнего запроса показывает сервер.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if let validationError { Text(validationError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Spacer()
                Button("Отменить правки") {
                    draft = assistant.settings
                    stopText = draft.options.stop.joined(separator: "\n")
                    validationError = nil
                }
                Button("Применить") {
                    do {
                        // Enabling assistance is controlled independently in the lyrics editor.
                        draft.enabled = assistant.settings.enabled
                        draft.options.stop = stopText.components(separatedBy: "\n").filter { !$0.isEmpty }
                        try assistant.applySettings(draft)
                        validationError = nil; message = "Настройки сохранены."
                    } catch { validationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }.padding(12)
        }.frame(width: 640, height: 740)
    }
    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
    }
    private func decimalField(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
    }
    private func loadModels() {
        isLoading = true; message = nil
        let settings = draft
        Task { @MainActor in
            defer { isLoading = false }
            do {
                models = try await assistant.models(settings: settings)
                message = models.isEmpty ? "Ollama доступна, установленных моделей нет." : "Ollama доступна: \(models.count) моделей."
            } catch { message = error.localizedDescription }
        }
    }
}

struct RhymeContextPanel: View {
    let assistant: RhymeAssistant
    var body: some View {
        let usage = assistant.contextUsage
        VStack(alignment: .leading, spacing: 6) {
            Text("Контекст песни").font(.caption.bold())
            ProgressView(value: usage.fraction).tint(usage.isFull ? .orange : .teal)
                .accessibilityLabel("Заполнение контекстного окна Ollama")
            Text("≈ \(usage.total) / \(usage.capacity) токенов · оценка с резервом ответа")
                .font(.caption2).foregroundStyle(usage.isFull ? .orange : .secondary).monospacedDigit()
            if let input = assistant.lastPromptTokens, let output = assistant.lastOutputTokens {
                Text("Последний ответ: вход \(input), выход \(output) токенов").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(assistant.isCompressing ? "Сжатие · часть \(assistant.compressionStep)…" : "Сжать контекст") { assistant.compressContext() }
                    .disabled(!assistant.canCompress)
                if assistant.isCompressing { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button { assistant.resetContext() } label: { Image(systemName: "trash") }
                    .help("Очистить историю анализа, сохранив текст песни")
            }.controlSize(.small)
            if let error = assistant.contextError { Text(error).font(.caption2).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
