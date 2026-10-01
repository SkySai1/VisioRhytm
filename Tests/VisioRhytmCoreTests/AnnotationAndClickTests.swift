import Foundation
import Testing
@testable import VisioRhytmCore

@Test func annotationsAreExcludedButOriginalLyricsRemain() throws {
    var project = Project()
    project.lyrics = "[Куплет]\r\nВойна (тихо) на [пауза] фронте\r\n(Проигрыш)\r\n\r\nМы[ремарка] строим защиту"
    project.lines = try LyricsEngine().parse(project.lyrics, signature: project.timeSignature)
    #expect(project.lines.count == 2)
    #expect(project.lines[0].originalText == "Война (тихо) на [пауза] фронте")
    #expect(project.lines.map(\.renderedWords) == [["Война", "на", "фронте"], ["Мы", "строим", "защиту"]])
    #expect(project.lines.allSatisfy { !$0.renderedText.contains("[") && !$0.renderedText.contains("(") })
    #expect(try ProjectStore().decode(ProjectStore().encode(project)) == project)
}

@Test func nestedAndMultilineAnnotationsRetainSourceLineMapping() throws {
    var project = Project()
    project.lyrics = "[Intro\n(guitar [fade])\n]\nДо (скрытый\nголос) света\nКонец"
    let engine = LyricsEngine()
    let sources = engine.canvasLines(project.lyrics)
    #expect(sources.map(\.sourceLineIndex) == [3, 4, 5])
    #expect(sources.map(\.canvasText) == ["До", "света", "Конец"])
    project.lines = try engine.parse(project.lyrics, signature: project.timeSignature)
    try engine.rebuild(&project.lines[1], manual: "све|та", textForCanvas: sources[1].canvasText)
    #expect(project.lines[1].originalText == "голос) света")
    #expect(project.lines[1].renderedText == "света")
    #expect(try ProjectStore().decode(ProjectStore().encode(project)) == project)
}

@Test func unfinishedAnnotationsDoNotHideRemainingLyrics() {
    let engine = LyricsEngine()
    #expect(engine.canvasText("Текст (без закрытия") == "Текст (без закрытия")
    #expect(engine.canvasText("Текст ] здесь") == "Текст ] здесь")
    #expect(engine.canvasText("до(ремарка)после").split(whereSeparator: \.isWhitespace).map(String.init) == ["до", "после"])
    #expect(engine.canvasText("[незакрытая (закрытая) ремарка").split(whereSeparator: \.isWhitespace).map(String.init) == ["[незакрытая", "ремарка"])
}

@Test func annotationOnlyProjectsHaveNoTracksAndCanBeSaved() throws {
    var project = Project()
    project.lyrics = "[Verse]\n(Instrumental)\n[Outro\n(guitar)]"
    project.lines = try LyricsEngine().parse(project.lyrics, signature: project.timeSignature)
    #expect(project.lines.isEmpty)
    #expect(try ProjectStore().decode(ProjectStore().encode(project)) == project)
}

@Test func manualBoundariesApplyOnlyToVisibleWords() throws {
    var line = LyricsLine(text: "Невидимом [пауза] фронте (тихо)", length: 3840)
    try LyricsEngine().rebuild(&line, manual: "Не|видимом фрон|те")
    #expect(line.syllables.map(\.text) == ["Не", "видимом", "фрон", "те"])
    #expect(line.originalText == "Невидимом [пауза] фронте (тихо)")
    #expect(throws: LyricsError.self) {
        try LyricsEngine().rebuild(&line, manual: "Не|видимом [пауза] фрон|те (тихо)")
    }
}

@Test func legacyProjectsRebuildAnnotationsAndPreserveUnaffectedPositions() throws {
    var legacy = Project()
    legacy.lyrics = "[Куплет]\nВойна (тихо) на фронте\nОбычная строка"
    for text in legacy.lyrics.components(separatedBy: "\n") {
        var line = LyricsLine(text: text, length: 3840)
        for (wordIndex, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            for chunk in RussianSyllabifier().syllabify(String(word)) {
                line.syllables.append(Syllable(text: chunk, index: line.syllables.count, wordIndex: wordIndex))
            }
        }
        LyricsEngine().layout(&line)
        legacy.lines.append(line)
    }
    legacy.lines[1].manualOverrides = "Вой|на (ти|хо) на фрон|те"
    let data = try JSONEncoder().encode(legacy)
    let restored = try ProjectStore().decode(data)
    #expect(restored.lyrics == legacy.lyrics)
    #expect(restored.lines.count == 2)
    #expect(restored.lines[0].id == legacy.lines[1].id)
    #expect(restored.lines[0].rhythmicLength == legacy.lines[1].rhythmicLength)
    #expect(restored.lines[0].renderedWords == ["Война", "на", "фронте"])
    #expect(restored.lines[0].manualOverrides?.split(whereSeparator: \.isWhitespace).map(String.init) == ["Вой|на", "на", "фрон|те"])
    #expect(restored.lines[1] == legacy.lines[2])
    #expect(try ProjectStore().decode(ProjectStore().encode(restored)) == restored)
    legacy.lines[1].syllables[0].text = "ошибка"
    #expect(throws: ProjectError.self) { try ProjectStore().decode(JSONEncoder().encode(legacy)) }
}

@Test func clickColumnsFollowPreviewAndPlaybackRange() {
    var project = Project()
    project.subdivision = .sixteenth
    #expect(RhythmEngine.clickAccent(at: 0, project: project) == .primary)
    #expect(RhythmEngine.clickAccent(at: 120, project: project) == nil)
    #expect(RhythmEngine.clickAccent(at: 480, project: project) == .regular)
    #expect(RhythmEngine.clickAccent(at: 960, project: project) == .secondary)
    project.metronomeSettings.previewSubdivision = true
    #expect(RhythmEngine.clickAccent(at: 120, project: project) == .subdivision)
    project.metronomeSettings.loopEnabled = false
    project.metronomeSettings.loopStartBar = 2
    project.metronomeSettings.loopEndBar = 2
    #expect(RhythmEngine.clickAccent(at: 0, project: project) == nil)
    #expect(RhythmEngine.clickAccent(at: 1920, project: project) == .primary)
    #expect(RhythmEngine.clickAccent(at: 3840, project: project) == nil)
    project.timeSignature = .init(6, 8)
    project.subdivision = .quarter
    #expect(RhythmEngine.clickAccent(at: 1440 + 240, project: project) == .regular)
    #expect(RhythmEngine.clickAccent(at: 1440 + 720, project: project) == .secondary)
}
