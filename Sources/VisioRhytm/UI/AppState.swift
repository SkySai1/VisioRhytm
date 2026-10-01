import AppKit
import Observation
import UniformTypeIdentifiers
import VisioRhytmCore
import VisioRhytmAudio

@MainActor @Observable
final class AppState {
    var project: Project
    var lyricsDraft: String {
        didSet { if lyricsDraft != oldValue { scheduleCanvasUpdate() } }
    }
    private(set) var liveCanvasEnabled = false
    private(set) var autoFitEnabled = false
    var showSectionSpacing = true
    private(set) var canvasUpdateError: String?
    var zoom: Double = 1
    var showClickStripes = true
    var errorMessage: String?
    var selectedLineID: UUID?
    private(set) var fileURL: URL?
    private var cleanProject: Project
    var isDirty: Bool { project != cleanProject }
    var hasUnsavedChanges: Bool { isDirty || lyricsDraft != project.lyrics }
    private(set) var recoveryMessage: String?
    private var fitSnapshot: FitSnapshot?
    var canResetLineFit: Bool {
        guard let snapshot = fitSnapshot, snapshot.projectID == project.id else { return false }
        return project.lines.contains { snapshot.lines[$0.id] != nil }
    }

    private struct FitSnapshot {
        let projectID: UUID
        let lines: [UUID: LyricsLine]
    }
    let metronome = MetronomeEngine()
    let rhymeAssistant: RhymeAssistant
    @ObservationIgnored private let store = ProjectStore()
    @ObservationIgnored private let lyricsEngine = LyricsEngine()
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var canvasUpdateTask: Task<Void, Never>?
    @ObservationIgnored private let autosaveURL: URL
    @ObservationIgnored private let confirmDiscard: (() -> Bool)?

    init(autosaveURL customAutosaveURL: URL? = nil, confirmDiscard: (() -> Bool)? = nil, rhymeAssistant: RhymeAssistant? = nil) {
        self.rhymeAssistant = rhymeAssistant ?? RhymeAssistant()
        self.confirmDiscard = confirmDiscard
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        autosaveURL = customAutosaveURL ?? support.appendingPathComponent("VisioRhytm/Autosave.visiorhythm")
        var initial = Self.makeNewProject()
        if FileManager.default.fileExists(atPath: autosaveURL.path) {
            do {
                initial = try store.load(from: autosaveURL)
                recoveryMessage = "Восстановлена последняя рабочая сессия. Сохраните её в файл проекта."
            } catch {
                recoveryMessage = "Не удалось прочитать autosave: \(error.localizedDescription). Исходный файл сохранён."
            }
        }
        project = initial
        cleanProject = initial
        lyricsDraft = initial.lyrics
        metronome.onFailure = { [weak self] in self?.errorMessage = $0 }
    }

    static let exampleLyrics = "Война на невидимом фронте\nГде враг растворяется в сети\nМы строим защиту сегодня\nЧтоб завтра систему спасти"
    private static func makeNewProject() -> Project {
        var project = Project()
        project.lyrics = exampleLyrics
        // Fixed bundled text is within the parser's limits.
        project.lines = (try? LyricsEngine().parse(project.lyrics, signature: project.timeSignature)) ?? []
        return project
    }
    func setLiveCanvasEnabled(_ enabled: Bool) {
        canvasUpdateTask?.cancel()
        liveCanvasEnabled = enabled
        canvasUpdateError = nil
        if enabled, lyricsDraft != project.lyrics { _ = applyLyrics(reportErrors: false) }
    }
    private func scheduleCanvasUpdate() {
        canvasUpdateTask?.cancel()
        canvasUpdateError = nil
        guard liveCanvasEnabled, lyricsDraft != project.lyrics else { return }
        let draft = lyricsDraft, projectID = project.id
        canvasUpdateTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.liveCanvasEnabled, self.project.id == projectID, self.lyricsDraft == draft else { return }
            _ = self.applyLyrics(reportErrors: false)
        }
    }
    func setAutoFitEnabled(_ enabled: Bool) {
        if !enabled {
            autoFitEnabled = false
            if liveCanvasEnabled, lyricsDraft != project.lyrics { _ = applyLyrics(reportErrors: false) }
            return
        }
        do {
            let fitted = try fitting(project)
            rememberLineFit(project.lines)
            autoFitEnabled = true
            edit { $0 = fitted }
            if liveCanvasEnabled, lyricsDraft != project.lyrics { _ = applyLyrics(reportErrors: false) }
        } catch { errorMessage = error.localizedDescription }
    }

    func edit(_ change: (inout Project) -> Void, audio: Bool = false) {
        change(&project)
        changed()
        if audio { perform { try metronome.reconfigure(project: project) } }
    }
    func setTimeSignature(_ signature: TimeSignature) {
        if rhythmChange({ $0.timeSignature = signature }) { perform { try metronome.reconfigure(project: project) } }
    }
    func setPlaybackStartBar(_ bar: Int) {
        guard rhythmChange({
            $0.metronomeSettings.loopStartBar = min(256, max(1, bar))
            $0.metronomeSettings.loopEndBar = max($0.metronomeSettings.loopStartBar, $0.metronomeSettings.loopEndBar)
        }) else { return }
        perform { try metronome.updatePlaybackRange(project: project) }
    }
    func setPlaybackEndBar(_ bar: Int) {
        guard rhythmChange({ $0.metronomeSettings.loopEndBar = min(256, max($0.metronomeSettings.loopStartBar, bar)) }) else { return }
        perform { try metronome.updatePlaybackRange(project: project) }
    }
    private func rhythmChange(_ change: (inout Project) -> Void) -> Bool {
        do {
            var candidate = project
            change(&candidate)
            try commit(candidate)
            if liveCanvasEnabled, lyricsDraft != project.lyrics { _ = applyLyrics(reportErrors: false) }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private func commit(_ candidate: Project) throws {
        let prepared = autoFitEnabled ? try fitting(candidate) : candidate
        if autoFitEnabled { rememberLineFit(candidate.lines) }
        project = prepared
        changed()
    }
    private func changed() {
        if !canResetLineFit { fitSnapshot = nil }
        autosaveTask?.cancel()
        let snapshot = project
        let url = autosaveURL
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                try ProjectStore().save(snapshot, to: url)
            } catch is CancellationError {} catch {
                self?.errorMessage = "Ошибка autosave: \(error.localizedDescription)"
            }
        }
    }
    @discardableResult func applyLyrics(reportErrors: Bool = true) -> Bool {
        canvasUpdateTask?.cancel()
        do {
            let lines = try lyricsEngine.parse(lyricsDraft, signature: project.timeSignature, preserving: project.lines, preservingEdits: liveCanvasEnabled)
            var candidate = project
            candidate.lyrics = lyricsDraft; candidate.lines = lines
            try commit(candidate)
            canvasUpdateError = nil
            if let selectedLineID, !lines.contains(where: { $0.id == selectedLineID }) { self.selectedLineID = nil }
            return true
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
            else { canvasUpdateError = error.localizedDescription }
            return false
        }
    }
    func updateLine(_ id: UUID, change: (inout LyricsLine) throws -> Void) {
        guard let index = project.lines.firstIndex(where: { $0.id == id }) else { return }
        do {
            let hasDraft = lyricsDraft != project.lyrics
            var candidate = project
            var line = project.lines[index]
            try change(&line)
            lyricsEngine.layout(&line)
            if line.originalText != project.lines[index].originalText {
                let source = lyricsEngine.canvasLines(project.lyrics)[index]
                let lyrics = lyricsEngine.replacingSourceLine(in: project.lyrics, at: source.sourceLineIndex, with: line.originalText)
                var candidates = project.lines
                candidates[index] = line
                let rebuilt = try lyricsEngine.parse(lyrics, signature: project.timeSignature, preserving: candidates)
                candidate.lyrics = lyrics
                candidate.lines = rebuilt
            } else {
                candidate.lines[index] = line
            }
            try commit(candidate)
            if !hasDraft { lyricsDraft = project.lyrics }
        } catch { errorMessage = error.localizedDescription }
    }
    func setBars(_ id: UUID, bars: Int) {
        let length = Int64(bars) * project.timeSignature.barTicks
        updateLine(id) { $0.rhythmicLength.ticks = length }
    }
    func fitLinesToPlaybackRange() {
        guard !project.lines.isEmpty else { return }
        perform {
            let fitted = try fitting(project)
            rememberLineFit(project.lines)
            edit { $0 = fitted }
        }
    }
    private func fitting(_ candidate: Project) throws -> Project {
        let range = RhythmEngine.playbackRange(project: candidate)
        let length = range.upperBound - range.lowerBound
        var fitted = candidate
        for index in fitted.lines.indices {
            guard Int64(fitted.lines[index].syllables.count) <= length else {
                throw ProjectError.invalid("в строке \(index + 1) слишком много слогов для выбранного диапазона. Увеличьте число тактов")
            }
            fitted.lines[index].startPosition.ticks = range.lowerBound
            fitted.lines[index].rhythmicLength.ticks = length
            lyricsEngine.layout(&fitted.lines[index])
        }
        try store.validate(fitted)
        return fitted
    }
    private func rememberLineFit(_ lines: [LyricsLine]) {
        var originals = canResetLineFit ? fitSnapshot!.lines : [:]
        for line in lines where originals[line.id] == nil {
            originals[line.id] = line
        }
        fitSnapshot = FitSnapshot(projectID: project.id, lines: originals)
    }
    func resetLineFit() {
        guard canResetLineFit, let snapshot = fitSnapshot else { return }
        perform {
            var restored = project
            for index in restored.lines.indices {
                guard let original = snapshot.lines[restored.lines[index].id] else { continue }
                restored.lines[index].startPosition = original.startPosition
                restored.lines[index].rhythmicLength = original.rhythmicLength
                if restored.lines[index].syllables.map(\.id) == original.syllables.map(\.id) {
                    for syllableIndex in restored.lines[index].syllables.indices {
                        restored.lines[index].syllables[syllableIndex].position = original.syllables[syllableIndex].position
                        restored.lines[index].syllables[syllableIndex].duration = original.syllables[syllableIndex].duration
                    }
                } else {
                    guard Int64(restored.lines[index].syllables.count) <= original.rhythmicLength.ticks else {
                        throw ProjectError.invalid("в строке \(index + 1) слишком много слогов для прежней длины. Сократите текст перед сбросом подгонки")
                    }
                    lyricsEngine.layout(&restored.lines[index])
                }
            }
            try store.validate(restored)
            autoFitEnabled = false
            fitSnapshot = nil
            edit { $0 = restored }
        }
    }
    func setDensity(_ id: UUID, density: Double) {
        let signature = project.timeSignature
        updateLine(id) {
            $0.rhythmicLength.ticks = min(signature.barTicks * 32,
                RhythmEngine.length(syllableCount: $0.syllables.count, density: density, signature: signature))
        }
    }
    func reset(_ id: UUID) {
        let visible = canvasText(forLine: id)
        updateLine(id) { try lyricsEngine.rebuild(&$0, textForCanvas: visible) }
    }
    func canvasText(forLine id: UUID, replacingText text: String? = nil) -> String {
        guard let index = project.lines.firstIndex(where: { $0.id == id }) else { return "" }
        let source = lyricsEngine.canvasLines(project.lyrics)[index]
        guard let text else { return source.canvasText }
        let lyrics = lyricsEngine.replacingSourceLine(in: project.lyrics, at: source.sourceLineIndex, with: text)
        return lyricsEngine.sourceLines(lyrics)[source.sourceLineIndex].canvasText
    }
    func editLine(_ id: UUID, text: String, manual: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains(where: \.isNewline) else {
            errorMessage = "Введите одну непустую строку."; return
        }
        let visible = canvasText(forLine: id, replacingText: text)
        updateLine(id) {
            $0.originalText = text.trimmingCharacters(in: .whitespaces)
            try lyricsEngine.rebuild(&$0, manual: manual, textForCanvas: visible)
        }
    }
    func togglePlayback() {
        perform {
            if metronome.isPlaying { metronome.stop() }
            else { try metronome.start(project: project) }
        }
    }
    func returnToStart() { perform { try metronome.returnToStart(project: project) } }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
    private func mayDiscard() -> Bool {
        guard hasUnsavedChanges else { return true }
        if let confirmDiscard { return confirmDiscard() }
        let alert = NSAlert()
        alert.messageText = "Сохранить текущий проект?"
        alert.informativeText = "В проекте есть несохранённые изменения."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Не сохранять")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func newProject() {
        guard mayDiscard() else { return }
        replace(with: Self.makeNewProject(), url: nil)
    }
    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.visioRhytmProject, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURL(url)
    }
    @discardableResult func openURL(_ url: URL) -> Bool {
        // Finder and SwiftUI may deliver the same file-open event twice.
        guard fileURL?.standardizedFileURL != url.standardizedFileURL else { return true }
        do {
            let loaded = try store.load(from: url)
            guard mayDiscard() else { return false }
            replace(with: loaded, url: url)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    private func replace(with newProject: Project, url: URL?) {
        canvasUpdateTask?.cancel()
        canvasUpdateError = nil
        autoFitEnabled = false
        metronome.stop()
        rhymeAssistant.resetContext()
        fitSnapshot = nil
        project = newProject
        cleanProject = newProject
        lyricsDraft = newProject.lyrics
        fileURL = url
        recoveryMessage = nil
        selectedLineID = nil
        changed()
        returnToStart()
    }
    @discardableResult func save(as saveAs: Bool = false) -> Bool {
        if lyricsDraft != project.lyrics && !applyLyrics() { return false }
        var destination = fileURL
        if saveAs || destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.visioRhytmProject]
            panel.nameFieldStringValue = project.title + ".visiorhythm"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }
        do {
            try store.save(project, to: destination)
            fileURL = destination
            cleanProject = project
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func prepareToQuit() -> Bool {
        guard mayDiscard() else { return false }
        metronome.stop()
        canvasUpdateTask?.cancel()
        autosaveTask?.cancel()
        perform { try store.save(project, to: autosaveURL) }
        return true
    }
    func dismissRecovery() { recoveryMessage = nil }
}

extension UTType {
    static let visioRhytmProject = UTType(exportedAs: "com.visiorhytm.project", conformingTo: .json)
}
