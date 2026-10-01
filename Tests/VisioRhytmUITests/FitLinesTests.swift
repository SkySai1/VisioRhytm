import Foundation
import Testing
import VisioRhytmCore
@testable import VisioRhytm

@Test(arguments: TimeSignature.supported)
@MainActor func fittingLinesUsesWholeSelectedRangeAndPreservesText(signature: TimeSignature) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.lyricsDraft = "[Куплет]\nВойна (тихо) на фронте\n\nДругой текст\n"
    #expect(state.applyLyrics())
    let firstID = try #require(state.project.lines.first?.id)
    state.editLine(firstID, text: "Война (тихо) на фронте", manual: "Вой|на на фрон|те")
    state.setTimeSignature(signature)
    state.setPlaybackStartBar(5)
    state.setPlaybackEndBar(8)
    state.setDensity(firstID, density: 3)
    let before = state.project
    state.lyricsDraft += "Неприменённая строка"
    let draft = state.lyricsDraft
    state.fitLinesToPlaybackRange()
    let range = RhythmEngine.playbackRange(project: before)
    for (old, fitted) in zip(before.lines, state.project.lines) {
        #expect(fitted.id == old.id)
        #expect(fitted.originalText == old.originalText)
        #expect(fitted.manualOverrides == old.manualOverrides)
        #expect(fitted.syllables.map(\.id) == old.syllables.map(\.id))
        #expect(fitted.syllables.map(\.text) == old.syllables.map(\.text))
        #expect(fitted.startPosition.ticks == range.lowerBound)
        #expect(fitted.endTicks == range.upperBound)
        #expect(RhythmEngine.bars(for: fitted, signature: signature) == 4)
        #expect(RhythmEngine.density(for: fitted, signature: signature)
                == Double(fitted.syllables.count) / Double(signature.numerator * 4))
        #expect(fitted.syllables.first?.position.ticks == 0)
        let last = try #require(fitted.syllables.last)
        #expect(last.position.ticks + last.duration.ticks == fitted.rhythmicLength.ticks)
        for pair in zip(fitted.syllables, fitted.syllables.dropFirst()) {
            #expect(pair.0.position.ticks + pair.0.duration.ticks == pair.1.position.ticks)
        }
    }
    #expect(state.project.lyrics == before.lyrics)
    #expect(state.lyricsDraft == draft)
    #expect(state.project.metronomeSettings == before.metronomeSettings)
    #expect(state.project.bpm == before.bpm)
    #expect(state.isDirty)
    #expect(state.errorMessage == nil)
    #expect(try ProjectStore().decode(ProjectStore().encode(state.project)) == state.project)
}

@Test @MainActor func fittingOneBarIsAtomicWhenASyllableCannotHavePositiveDuration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.lyricsDraft = "Короткая строка\n" + String(repeating: "а ", count: 1500)
    #expect(state.applyLyrics())
    state.setTimeSignature(.init(3, 4))
    state.setPlaybackEndBar(1)
    let before = state.project
    state.fitLinesToPlaybackRange()
    #expect(state.project == before)
    #expect(state.errorMessage?.contains("строке 2") == true)
    #expect(!state.canResetLineFit)
}

@Test(arguments: TimeSignature.supported)
@MainActor func resetFitRestoresOriginalGeometryAfterRepeatedFitting(signature: TimeSignature) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.setTimeSignature(signature)
    state.lyricsDraft = "[Куплет]\nВойна (тихо) на фронте\nДругой текст"
    #expect(state.applyLyrics())
    let first = try #require(state.project.lines.first?.id)
    let second = try #require(state.project.lines.last?.id)
    state.editLine(first, text: "Война (тихо) на фронте", manual: "Вой|на на фрон|те")
    state.setDensity(first, density: 3)
    state.setBars(second, bars: 2)
    state.edit {
        $0.lines[1].startPosition.ticks = signature.barTicks
        // A nonuniform layout must be restored exactly, including a leading pause.
        $0.lines[0].syllables[0].position.ticks += 1
        $0.lines[0].syllables[0].duration.ticks -= 1
    }
    let originalLines = state.project.lines
    #expect(!state.canResetLineFit)
    state.resetLineFit()
    #expect(state.project.lines == originalLines)
    state.setPlaybackStartBar(5)
    state.setPlaybackEndBar(8)
    state.fitLinesToPlaybackRange()
    #expect(state.canResetLineFit)
    state.setPlaybackEndBar(9)
    state.fitLinesToPlaybackRange()
    state.lyricsDraft += "\nНеприменённый черновик"
    let draft = state.lyricsDraft
    let settings = state.project.metronomeSettings
    state.resetLineFit()
    #expect(state.project.lines == originalLines)
    #expect(state.project.metronomeSettings == settings)
    #expect(state.lyricsDraft == draft)
    #expect(!state.canResetLineFit)
    #expect(state.errorMessage == nil)
    #expect(state.isDirty)
    #expect(try ProjectStore().decode(ProjectStore().encode(state.project)) == state.project)
    state.resetLineFit()
    #expect(state.project.lines == originalLines)
    state.setBars(first, bars: 4)
    let nextOriginals = state.project.lines
    state.fitLinesToPlaybackRange()
    state.resetLineFit()
    #expect(state.project.lines == nextOriginals)
}

@Test @MainActor func resetFitPreservesTextEditsAndIncludesNewlyFittedLines() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.lyricsDraft = "Война на фронте\nДругой текст"
    #expect(state.applyLyrics())
    let first = try #require(state.project.lines.first?.id)
    let second = try #require(state.project.lines.last?.id)
    state.setBars(first, bars: 1)
    state.setBars(second, bars: 2)
    let originals = state.project.lines
    state.setPlaybackStartBar(5)
    state.setPlaybackEndBar(8)
    state.fitLinesToPlaybackRange()
    state.editLine(first, text: "Война (громко) на фронте", manual: "Война на фрон|те")
    state.editLine(second, text: "[Удалённая строка]", manual: nil)
    state.lyricsDraft += "\nНовая строка"
    #expect(state.applyLyrics())
    let newLine = try #require(state.project.lines.last)
    state.fitLinesToPlaybackRange()
    let source = state.project.lyrics
    let edited = state.project.lines[0]
    state.resetLineFit()
    let restored = state.project.lines[0]
    #expect(restored.originalText == edited.originalText)
    #expect(restored.manualOverrides == edited.manualOverrides)
    #expect(restored.syllables.map(\.id) == edited.syllables.map(\.id))
    #expect(restored.syllables.map(\.text) == edited.syllables.map(\.text))
    #expect(restored.startPosition == originals[0].startPosition)
    #expect(restored.rhythmicLength == originals[0].rhythmicLength)
    #expect(restored.syllables.last!.position.ticks + restored.syllables.last!.duration.ticks == restored.rhythmicLength.ticks)
    #expect(state.project.lines.last == newLine)
    #expect(state.project.lines.count == 2)
    #expect(state.project.lyrics == source)
    #expect(!state.canResetLineFit)
    #expect(state.errorMessage == nil)
    try ProjectStore().validate(state.project)
}

@Test @MainActor func resetFitFailureKeepsSnapshotAndDoesNotPartiallyRestore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.lyricsDraft = "Первая строка\nВторая строка"
    #expect(state.applyLyrics())
    let second = try #require(state.project.lines.last?.id)
    state.setBars(second, bars: 1)
    let originals = state.project.lines
    state.fitLinesToPlaybackRange()
    state.editLine(second, text: String(repeating: "а ", count: 2000), manual: nil)
    let before = state.project
    state.resetLineFit()
    #expect(state.project == before)
    #expect(state.canResetLineFit)
    #expect(state.errorMessage?.contains("строке 2") == true)
    state.errorMessage = nil
    state.editLine(second, text: "Исправленная строка", manual: nil)
    state.resetLineFit()
    #expect(state.project.lines.map(\.rhythmicLength) == originals.map(\.rhythmicLength))
    #expect(!state.canResetLineFit)
    #expect(state.errorMessage == nil)
    state.fitLinesToPlaybackRange()
    #expect(state.canResetLineFit)
    state.lyricsDraft = "Полностью новый текст"
    #expect(state.applyLyrics())
    #expect(!state.canResetLineFit)
}
