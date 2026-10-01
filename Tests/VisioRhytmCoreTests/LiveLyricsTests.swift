import Foundation
import Testing
@testable import VisioRhytmCore

@Test func incrementalTextEditsPreserveRhythmAndUnaffectedManualBoundaries() throws {
    let engine = LyricsEngine()
    var old = try engine.parse("Первая строка\nВторая строка", signature: .init(4, 4))
    old[0].startPosition.ticks = 1920
    old[0].rhythmicLength.ticks = 7680
    engine.layout(&old[0])
    try engine.rebuild(&old[1], manual: "Вто|рая стро|ка")
    let edited = try engine.parse("Первая новая строка\nВставленная строка\nВторая строка", signature: .init(4, 4), preserving: old, preservingEdits: true)
    #expect(edited[0].id == old[0].id)
    #expect(edited[0].startPosition == old[0].startPosition)
    #expect(edited[0].rhythmicLength == old[0].rhythmicLength)
    #expect(!old.map(\.id).contains(edited[1].id))
    #expect(edited[1].rhythmicLength.ticks == 3840)
    #expect(edited[2] == old[1])
    let annotated = try engine.parse("Первая новая строка\nВставленная строка\nВторая (тихо) строка", signature: .init(4, 4), preserving: edited, preservingEdits: true)
    #expect(annotated[2].id == old[1].id)
    #expect(annotated[2].syllables == old[1].syllables)
    #expect(annotated[2].manualOverrides == old[1].manualOverrides)
}

@Test func insertedDeletedMovedAndDuplicateLinesKeepDistinctIdentities() throws {
    let engine = LyricsEngine(), meter = TimeSignature(4, 4)
    let old = try engine.parse("Первая\nВторая\nТретья", signature: meter)
    let inserted = try engine.parse("Новая\nПервая\nВторая\nТретья", signature: meter, preserving: old, preservingEdits: true)
    #expect(Array(inserted.dropFirst()) == old)
    let deleted = try engine.parse("Первая\nТретья", signature: meter, preserving: old, preservingEdits: true)
    #expect(deleted == [old[0], old[2]])
    let moved = try engine.parse("Третья\nПервая\nВторая", signature: meter, preserving: old, preservingEdits: true)
    #expect(moved == [old[2], old[0], old[1]])
    let duplicates = try engine.parse("Повтор\nПовтор\nКонец", signature: meter)
    let replacement = try engine.parse("Повтор\nПравка\nКонец", signature: meter, preserving: duplicates, preservingEdits: true)
    #expect(replacement[0] == duplicates[0])
    #expect(replacement[1].id == duplicates[1].id)
    #expect(replacement[2] == duplicates[2])
    #expect(Set(replacement.map(\.id)).count == 3)
    #expect(try engine.parse("", signature: meter, preserving: old, preservingEdits: true).isEmpty)
}

@Test func blankSeparatorsDistinguishActualEmptyLinesFromAnnotations() {
    let sources = LyricsEngine().canvasLines("\n[Куплет]\nПервая\r\n \r\n\r\n[Припев]\r\nВторая\n(пауза)\nТретья\n\n")
    #expect(sources.map(\.canvasText) == ["Первая", "Вторая", "Третья"])
    #expect(sources.map(\.blankLinesBefore) == [0, 2, 0])
}
