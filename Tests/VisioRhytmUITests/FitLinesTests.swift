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
}
