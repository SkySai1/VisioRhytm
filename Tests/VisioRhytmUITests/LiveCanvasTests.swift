import Foundation
import Testing
import VisioRhytmCore
@testable import VisioRhytm

@MainActor private func waitForCanvas(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Test @MainActor func liveCanvasCanBeEnabledDisabledAndKeepsEditedLineLength() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave"))
    state.lyricsDraft = "Первая строка\nВторая строка"
    #expect(state.applyLyrics())
    let id = try #require(state.project.lines.first?.id)
    state.setBars(id, bars: 4)
    let initial = state.project
    state.lyricsDraft = "Первая изменённая строка\nВторая строка"
    try await Task.sleep(for: .milliseconds(300))
    #expect(state.project == initial)
    state.setLiveCanvasEnabled(true)
    #expect(state.project.lyrics == state.lyricsDraft)
    #expect(state.project.lines[0].id == id)
    #expect(state.project.lines[0].rhythmicLength.ticks == 7680)
    state.lyricsDraft = "Черновая правка\nВторая строка"
    state.lyricsDraft = "Окончательная правка\nНовая строка\nВторая строка"
    try await waitForCanvas { state.project.lyrics == state.lyricsDraft }
    #expect(state.project.lines.count == 3)
    #expect(state.project.lines[0].id == id)
    #expect(state.project.lines[0].rhythmicLength.ticks == 7680)
    #expect(state.project.lines[2] == initial.lines[1])
    #expect(state.canvasUpdateError == nil)
    #expect(state.hasUnsavedChanges)
    let applied = state.project
    state.lyricsDraft = "Отложенный текст"
    state.setLiveCanvasEnabled(false)
    try await Task.sleep(for: .milliseconds(300))
    #expect(state.project == applied)
    #expect(state.applyLyrics())
    #expect(state.project.lyrics == "Отложенный текст")
}

@Test @MainActor func liveCanvasRetainsLastValidProjectOnParsingOrFitFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave"))
    state.setLiveCanvasEnabled(true)
    let initial = state.project
    state.lyricsDraft = String(repeating: "а", count: 100_001)
    try await waitForCanvas { state.canvasUpdateError != nil }
    #expect(state.project == initial)
    #expect(state.errorMessage == nil)
    state.lyricsDraft = "Короткая строка"
    try await waitForCanvas { state.project.lyrics == state.lyricsDraft }
    state.setTimeSignature(.init(3, 4))
    state.setPlaybackEndBar(1)
    state.setAutoFitEnabled(true)
    let fitted = state.project
    state.lyricsDraft = String(repeating: "а ", count: 1500)
    try await waitForCanvas { state.canvasUpdateError != nil }
    #expect(state.project == fitted)
    #expect(state.autoFitEnabled)
    #expect(state.errorMessage == nil)
    state.setAutoFitEnabled(false)
    #expect(state.project.lyrics == state.lyricsDraft)
    #expect(state.canvasUpdateError == nil)
    try ProjectStore().validate(state.project)
    state.lyricsDraft = "Короткая строка"
    try await waitForCanvas { state.project.lyrics == state.lyricsDraft }
    state.setAutoFitEnabled(true)
    state.lyricsDraft = String(repeating: "а ", count: 1500)
    try await waitForCanvas { state.canvasUpdateError != nil }
    state.setPlaybackEndBar(2)
    #expect(state.project.lyrics == state.lyricsDraft)
    #expect(state.canvasUpdateError == nil)
    #expect(state.autoFitEnabled)
    #expect(state.project.lines[0].rhythmicLength.ticks == 2880)
}

@Test @MainActor func automaticFitAppliesToFutureTextRangeAndMeterChangesAndReset() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave"))
    state.lyricsDraft = "Первая строка\nВторая строка"
    #expect(state.applyLyrics())
    let original = state.project.lines
    state.setPlaybackStartBar(5); state.setPlaybackEndBar(8)
    state.setAutoFitEnabled(true)
    #expect(state.autoFitEnabled)
    state.lyricsDraft += "\nНовая строка"
    #expect(state.applyLyrics())
    state.setPlaybackEndBar(9)
    state.setTimeSignature(.init(6, 8))
    let range = RhythmEngine.playbackRange(project: state.project)
    #expect(state.project.lines.count == 3)
    for line in state.project.lines {
        #expect(line.startPosition.ticks == range.lowerBound)
        #expect(line.endTicks == range.upperBound)
    }
    let fitted = state.project.lines
    state.edit { $0.bpm = 160 }
    #expect(state.project.lines == fitted)
    state.setAutoFitEnabled(false)
    state.setPlaybackEndBar(10)
    #expect(state.project.lines == fitted)
    state.setAutoFitEnabled(true)
    state.resetLineFit()
    #expect(!state.autoFitEnabled)
    #expect(!state.canResetLineFit)
    #expect(Array(state.project.lines.prefix(2)) == original)
    #expect(state.project.lines[2].startPosition.ticks == 0)
    #expect(state.project.lines[2].rhythmicLength.ticks == 3840)
}

@Test @MainActor func failedFitDoesNotEnableCheckboxOrPartiallyChangeRange() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave"))
    state.lyricsDraft = String(repeating: "а ", count: 1500)
    #expect(state.applyLyrics())
    state.setTimeSignature(.init(3, 4)); state.setPlaybackEndBar(1)
    let initial = state.project
    state.setAutoFitEnabled(true)
    #expect(!state.autoFitEnabled)
    #expect(state.project == initial)
    state.errorMessage = nil
    state.setPlaybackEndBar(2); state.setAutoFitEnabled(true)
    let fitted = state.project
    state.setPlaybackEndBar(1)
    #expect(state.project == fitted)
    #expect(state.autoFitEnabled)
    #expect(state.errorMessage != nil)
}

@Test @MainActor func newProjectSeedsExampleButOpeningAndRecoveryDoNot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let autosave = directory.appendingPathComponent("Autosave"), file = directory.appendingPathComponent("Empty.visiorhythm")
    let state = AppState(autosaveURL: autosave, confirmDiscard: { true })
    #expect(state.project.lyrics == AppState.exampleLyrics)
    #expect(state.project.lines.count == 4)
    #expect(!state.hasUnsavedChanges)
    state.setLiveCanvasEnabled(true)
    state.setAutoFitEnabled(true)
    state.lyricsDraft = "Устаревший черновик"
    state.newProject()
    try await Task.sleep(for: .milliseconds(300))
    #expect(state.project.lyrics == AppState.exampleLyrics)
    #expect(state.lyricsDraft == AppState.exampleLyrics)
    #expect(!state.autoFitEnabled)
    #expect(!state.hasUnsavedChanges)
    let empty = Project()
    try ProjectStore().save(empty, to: file)
    #expect(state.openURL(file))
    #expect(state.project == empty)
    #expect(!state.hasUnsavedChanges)
    try ProjectStore().save(empty, to: autosave)
    let recovered = AppState(autosaveURL: autosave)
    #expect(recovered.project == empty)
    #expect(recovered.recoveryMessage != nil)
}

@Test @MainActor func sectionSpacingUsesSameRowsAndDoesNotAlterMusicalLayout() throws {
    var project = Project()
    project.lyrics = "\nПервая\n\n\n[Припев]\nВторая\nТретья\n(тихо)\nЧетвёртая\n\n"
    project.lines = try LyricsEngine().parse(project.lyrics, signature: project.timeSignature)
    let before = project
    let expanded = RhythmCanvasRowLayout(project: project, separateSections: true)
    #expect(expanded.gaps == [0, 32, 0, 0])
    #expect(expanded.tracksHeight == 4 * RhythmCanvas.rowHeight + 32)
    let compact = RhythmCanvasRowLayout(project: project, separateSections: false)
    #expect(compact.gaps == [0, 0, 0, 0])
    #expect(compact.tracksHeight == 4 * RhythmCanvas.rowHeight)
    #expect(project == before)
    #expect(try ProjectStore().decode(ProjectStore().encode(project)) == before)
}
