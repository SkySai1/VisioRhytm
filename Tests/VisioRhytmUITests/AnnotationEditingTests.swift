import Foundation
import Testing
import VisioRhytmCore
@testable import VisioRhytm

@Test @MainActor func lineControlsAndInspectorPreserveSourceAnnotations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    let original = "[Куплет]\n  Война (тихо) на фронте\n\n[Припев]\nДругой текст\n"
    state.lyricsDraft = original
    #expect(state.applyLyrics())
    let id = try #require(state.project.lines.first?.id)
    state.setBars(id, bars: 4)
    state.setDensity(id, density: 1.5)
    state.reset(id)
    #expect(state.project.lyrics == original)
    #expect(state.lyricsDraft == original)
    state.editLine(id, text: "Война (громко) на фронте", manual: "Вой|на на фрон|те")
    #expect(state.project.lyrics == "[Куплет]\nВойна (громко) на фронте\n\n[Припев]\nДругой текст\n")
    #expect(state.project.lines.first?.renderedText == "Война на фронте")
    try ProjectStore().validate(state.project)
    state.editLine(id, text: "[Комментарий]", manual: nil)
    #expect(state.project.lines.count == 1)
    #expect(state.project.lyrics.contains("[Комментарий]"))
    try ProjectStore().validate(state.project)
}

@Test @MainActor func editingMultilineAnnotationReanalyzesAffectedNeighbours() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.lyricsDraft = "Первая строка\nВторая строка\nТретья ] строка"
    #expect(state.applyLyrics())
    let first = try #require(state.project.lines.first?.id)
    let third = try #require(state.project.lines.last?.id)
    state.editLine(first, text: "[Комментарий", manual: nil)
    #expect(state.project.lines.count == 1)
    #expect(state.project.lines.first?.id == third)
    #expect(state.project.lines.first?.renderedText == "строка")
    #expect(state.project.lyrics == "[Комментарий\nВторая строка\nТретья ] строка")
    state.reset(third)
    #expect(state.project.lines.first?.renderedText == "строка")
    try ProjectStore().validate(state.project)
}
