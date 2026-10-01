import SwiftUI
import VisioRhytmCore
import VisioRhytmRhyme

struct MainWindow: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            TransportBar(state: state)
            Divider()
            RhythmSettingsPanel(state: state)
            Divider()
            if let message = state.recoveryMessage {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text(message).font(.caption)
                    Spacer()
                    Button("Закрыть") { state.dismissRecovery() }.buttonStyle(.borderless)
                }.padding(10).background(.orange.opacity(0.1))
            }
            HSplitView {
                LyricsEditor(state: state).frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ритмическое полотно").font(.title3.bold())
                            Text("Сравните объём текста в одном музыкальном пространстве.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Полосы кликов", isOn: $state.showClickStripes)
                            .toggleStyle(.checkbox).font(.caption)
                            .help("Показать или скрыть фиолетовые вертикальные полосы. Точки кликов остаются в линейке; звук не меняется.")
                        Image(systemName: "minus.magnifyingglass")
                        Slider(value: $state.zoom, in: 0.5...3).frame(width: 120).accessibilityLabel("Масштаб")
                        Image(systemName: "plus.magnifyingglass")
                        Text(state.zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 46)
                    }.padding(16)
                    HStack(spacing: 12) {
                        Button { state.fitLinesToPlaybackRange() } label: {
                            Label("Подогнать строки под такты", systemImage: "arrow.left.and.right")
                        }
                        .disabled(state.project.lines.isEmpty)
                        .help("Разместить все строки от первого до последнего выбранного такта и пересчитать плотность.")
                        Button { state.resetLineFit() } label: {
                            Label("Сбросить подгонку", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!state.canResetLineFit)
                        .help("Вернуть начало, длину и расположение слогов до первой подгонки в текущей сессии; сохранить изменения текста.")
                        let settings = state.project.metronomeSettings
                        Text("Диапазон \(settings.loopStartBar)–\(settings.loopEndBar) · \(settings.loopEndBar - settings.loopStartBar + 1) такт.")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                    Divider()
                    RhythmCanvas(state: state)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        MetricalStrengthLegend(signature: state.project.timeSignature)
                        HStack(spacing: 18) {
                            Label("Клик метронома", systemImage: "circle.fill").foregroundStyle(.purple)
                            Label("Текущая позиция", systemImage: "line.diagonal").foregroundStyle(.teal)
                            Text("Оценка объёма текста, а не прогноз вокальной партии.").foregroundStyle(.secondary)
                        }
                        HStack(spacing: 18) {
                            Label("Свободно", systemImage: "circle.fill").foregroundStyle(.teal)
                            Label("Умеренно", systemImage: "circle.fill").foregroundStyle(.blue)
                            Label("Плотно", systemImage: "circle.fill").foregroundStyle(.orange)
                        }
                    }.font(.caption).padding(12)
                }.frame(minWidth: 700)
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .alert("VisioRhytm", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { state.selectedLineID != nil }, set: { if !$0 { state.selectedLineID = nil } })) {
            if let id = state.selectedLineID, let line = state.project.lines.first(where: { $0.id == id }) {
                Inspector(state: state, line: line)
            }
        }
    }
}

struct TransportBar: View {
    @Bindable var state: AppState
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path").font(.title2).foregroundStyle(.teal)
            TextField("Название проекта", text: Binding(get: { state.project.title }, set: { title in state.edit { $0.title = String(title.prefix(500)) } }))
                .textFieldStyle(.plain).font(.title3.bold()).frame(maxWidth: 280)
            if state.hasUnsavedChanges { Circle().fill(.orange).frame(width: 7, height: 7).help("Несохранённые изменения") }
            Spacer()
            Button { state.returnToStart() } label: { Image(systemName: "backward.end.fill") }.help("Вернуться к началу, ⌘Return")
            Button { state.togglePlayback() } label: {
                Label(state.metronome.isPlaying ? "Stop" : "Play", systemImage: state.metronome.isPlaying ? "stop.fill" : "play.fill").frame(width: 70)
            }.buttonStyle(.borderedProminent).tint(.teal).help("Play / Stop, ⌘Space")
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !state.metronome.isPlaying)) { _ in
                let ticks = Int64(state.metronome.currentTicks())
                let end = RhythmEngine.playbackRange(project: state.project).upperBound
                let address = RhythmEngine.address(ticks: ticks, signature: state.project.timeSignature)
                Text(!state.project.metronomeSettings.loopEnabled && ticks >= end
                     ? "Конец · такт \(state.project.metronomeSettings.loopEndBar)"
                     : "Такт \(address.bar) · доля \(address.beat)")
                    .monospacedDigit().frame(width: 145, alignment: .leading)
            }
            Divider().frame(height: 24)
            Image(systemName: "speaker.wave.2")
            Slider(value: Binding(get: { state.project.metronomeSettings.volume }, set: { value in
                state.edit { $0.metronomeSettings.volume = value }
                state.metronome.setVolume(value)
            }), in: 0...1)
                .frame(width: 85).accessibilityLabel("Громкость метронома")
            Button { state.openProject() } label: { Image(systemName: "folder") }.help("Открыть проект")
            Button { state.save() } label: { Image(systemName: "square.and.arrow.down") }.help("Сохранить проект")
        }.padding(16)
    }
}

struct RhythmSettingsPanel: View {
    @Bindable var state: AppState
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("BPM").foregroundStyle(.secondary)
                TextField("BPM", value: Binding(get: { state.project.bpm }, set: { value in state.edit({ $0.bpm = min(240, max(40, value.isFinite ? value : 120)) }, audio: true) }), format: .number.precision(.fractionLength(0)))
                    .frame(width: 48).textFieldStyle(.roundedBorder)
                Stepper("BPM", value: Binding(get: { state.project.bpm }, set: { value in state.edit({ $0.bpm = value }, audio: true) }), in: 40...240).labelsHidden()
            }.help("40–240 четвертных в минуту. В 6/8 BPM также относится к четверти.")
            Picker("Размер", selection: Binding(get: { state.project.timeSignature }, set: { state.setTimeSignature($0) })) {
                ForEach(TimeSignature.supported, id: \.self) { Text($0.description).tag($0) }
            }.frame(width: 130)
            Picker("Сетка", selection: Binding(get: { state.project.subdivision }, set: { value in state.edit({ $0.subdivision = value }, audio: true) })) {
                ForEach(Subdivision.allCases, id: \.self) { Text($0.label).tag($0) }
            }.frame(width: 130)
            Toggle("Клики сетки", isOn: Binding(get: { state.project.metronomeSettings.previewSubdivision }, set: { value in state.edit({ $0.metronomeSettings.previewSubdivision = value }, audio: true) }))
            Divider().frame(height: 22)
            Toggle("Цикл", isOn: Binding(get: { state.project.metronomeSettings.loopEnabled }, set: { value in state.edit({ $0.metronomeSettings.loopEnabled = value }, audio: true) }))
            Text("Такты").foregroundStyle(.secondary)
            Stepper(value: Binding(get: { state.project.metronomeSettings.loopStartBar }, set: { state.setPlaybackStartBar($0) }), in: 1...256) {
                Text("\(state.project.metronomeSettings.loopStartBar)").monospacedDigit().frame(width: 24)
            }.fixedSize().accessibilityLabel("Первый такт воспроизведения")
            Text("–")
            Stepper(value: Binding(get: { state.project.metronomeSettings.loopEndBar }, set: { state.setPlaybackEndBar($0) }), in: state.project.metronomeSettings.loopStartBar...256) {
                Text("\(state.project.metronomeSettings.loopEndBar)").monospacedDigit().frame(width: 24)
            }.fixedSize().accessibilityLabel("Последний такт воспроизведения")
            Spacer(minLength: 0)
        }.font(.callout).padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct LyricsEditor: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Текст песни").font(.title3.bold())
            Text("Одна строка — одна дорожка. Пустые строки и текст в [] и () пропускаются.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Помощь с рифмой", isOn: Binding(get: { state.rhymeAssistant.settings.enabled }, set: { state.rhymeAssistant.setEnabled($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer(minLength: 0)
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Настройки Ollama, ⌘,")
            }
            if state.rhymeAssistant.settings.enabled {
                Picker("Контекст", selection: Binding(get: { state.rhymeAssistant.settings.mode }, set: { mode in
                    var settings = state.rhymeAssistant.settings; settings.mode = mode
                    state.perform { try state.rhymeAssistant.applySettings(settings) }
                })) {
                    Text("Соседние строки").tag(RhymeContextMode.nearbyLines)
                    Text("Вся песня").tag(RhymeContextMode.fullSong)
                }.font(.caption)
                HStack {
                    Text("Курсор — в конце строки").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { state.rhymeAssistant.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Подобрать новые окончания текущей строки")
                        .disabled(state.rhymeAssistant.isCompressing)
                }
            }
            LyricsTextEditor(text: $state.lyricsDraft, assistant: state.rhymeAssistant, presentation: state.rhymeAssistant.presentation)
                .frame(minHeight: 120)
                .background(.background).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("Исходный текст песни")
            if state.rhymeAssistant.settings.enabled && state.rhymeAssistant.settings.mode == .fullSong {
                RhymeContextPanel(assistant: state.rhymeAssistant)
            }
            Button("Разместить строки") { state.applyLyrics() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("Загрузить пример") { state.demo() }.buttonStyle(.borderless)
            Divider()
            Text("\(state.project.lines.count) строк · \(state.project.lines.reduce(0) { $0 + $1.syllables.count }) слогов")
                .font(.caption).foregroundStyle(.secondary)
            Text("Соседние строки начинаются с одного такта, чтобы их плотность было легко сравнить.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

struct LineControls: View {
    let state: AppState
    let line: LyricsLine
    let number: Int
    var body: some View {
        let density = RhythmEngine.density(for: line, signature: state.project.timeSignature)
        let bars = RhythmEngine.bars(for: line, signature: state.project.timeSignature)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(number)").foregroundStyle(.secondary).monospacedDigit()
                Text(line.renderedText).lineLimit(1).help(line.renderedText)
                Spacer(minLength: 0)
                Button { state.selectedLineID = line.id } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Текст и границы слогов")
                Button { state.reset(line.id) } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("Автоматическое разбиение и раскладка; сохранить длину")
            }.font(.caption)
            HStack(spacing: 4) {
                ForEach([1, 2, 4], id: \.self) { count in
                    Button("\(count)") { state.setBars(line.id, bars: count) }
                        .buttonStyle(.bordered).tint(abs(bars - Double(count)) < 0.01 ? .teal : nil)
                        .help("\(count) такт(а)")
                }
                Spacer(minLength: 0)
                Text(String(format: "%.2f такт.", bars)).font(.caption2).foregroundStyle(.secondary)
            }.controlSize(.mini)
            HStack(spacing: 6) {
                Slider(value: Binding(get: { min(6, max(0.25, density)) }, set: { state.setDensity(line.id, density: $0) }), in: 0.25...6)
                    .accessibilityLabel("Плотность строки \(number)")
                Text(String(format: "%.2f сл/д", density)).font(.caption2).monospacedDigit().frame(width: 65)
            }
            HStack(spacing: 6) {
                GeometryReader { proxy in
                    Capsule().fill(densityColor(density).opacity(0.2))
                    Capsule().fill(densityColor(density)).frame(width: proxy.size.width * min(1, density / 6))
                }.frame(height: 4)
                Text(RhythmEngine.category(density).rawValue).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12).frame(height: RhythmCanvas.rowHeight)
        .background(number.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
        .overlay(alignment: .bottom) { Divider() }
    }
}

func densityColor(_ density: Double) -> Color {
    switch RhythmEngine.category(density) {
    case .sparse: .teal
    case .moderate: .blue
    case .dense: .orange
    case .veryDense: .purple
    }
}

struct Inspector: View {
    let state: AppState
    let line: LyricsLine
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var boundaries: String
    @State private var useManual: Bool
    @State private var validationError: String?
    init(state: AppState, line: LyricsLine) {
        self.state = state; self.line = line
        _text = State(initialValue: line.originalText)
        _boundaries = State(initialValue: LyricsEngine().manualText(for: line))
        _useManual = State(initialValue: line.manualOverrides != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Редактирование строки").font(.title2.bold())
            TextField("Исходный текст", text: $text).textFieldStyle(.roundedBorder)
            Toggle("Задать границы слогов вручную", isOn: $useManual)
            Text("Разделяйте слоги знаком |, слова — пробелами. Используйте только текст вне [] и (): комментарии остаются в исходной строке, но не входят в слоги.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("не|ви|ди|мом", text: $boundaries).textFieldStyle(.roundedBorder).disabled(!useManual)
            Button("Получить автоматическое разбиение") {
                var copy = line; copy.originalText = text
                do {
                    try LyricsEngine().rebuild(&copy, textForCanvas: state.canvasText(forLine: line.id, replacingText: text))
                    boundaries = LyricsEngine().manualText(for: copy)
                    validationError = nil
                } catch { validationError = error.localizedDescription }
            }
            if let validationError { Text(validationError).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") {
                    do {
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains(where: \.isNewline) else {
                            throw ProjectError.invalid("нужна одна непустая строка")
                        }
                        var copy = line; copy.originalText = text.trimmingCharacters(in: .whitespaces)
                        try LyricsEngine().rebuild(&copy, manual: useManual ? boundaries : nil,
                                                  textForCanvas: state.canvasText(forLine: line.id, replacingText: text))
                        state.editLine(line.id, text: text, manual: useManual ? boundaries : nil)
                        dismiss()
                    } catch { validationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }
}
