import Foundation
import Testing
import VisioRhytmCore
@testable import VisioRhytm

@Test @MainActor func openingFileAfterAutosaveRecoveryDoesNotAskToSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let autosave = directory.appendingPathComponent("Autosave.visiorhythm")
    let file = directory.appendingPathComponent("Song.visiorhythm")
    var recovered = Project()
    recovered.title = "Предыдущая сессия"
    var song = Project()
    song.title = "Открываемый проект"
    song.metronomeSettings.loopStartBar = 5
    song.metronomeSettings.loopEndBar = 8
    try ProjectStore().save(recovered, to: autosave)
    try ProjectStore().save(song, to: file)
    var confirmations = 0
    let state = AppState(autosaveURL: autosave, confirmDiscard: { confirmations += 1; return false })
    #expect(state.project == recovered)
    #expect(state.recoveryMessage != nil)
    #expect(!state.hasUnsavedChanges)
    #expect(state.openURL(file))
    #expect(confirmations == 0)
    #expect(state.project == song)
    #expect(state.fileURL == file)
    #expect(state.lyricsDraft == song.lyrics)
    #expect(!state.isDirty)
    #expect(state.recoveryMessage == nil)
    #expect(state.metronome.currentTicks() == Double(RhythmEngine.playbackRange(project: song).lowerBound))
}

@Test @MainActor func noOpControlsAndRevertedChangesDoNotAskToSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstFile = directory.appendingPathComponent("First.visiorhythm")
    let secondFile = directory.appendingPathComponent("Second.visiorhythm")
    let first = Project()
    let second = Project()
    try ProjectStore().save(first, to: firstFile)
    try ProjectStore().save(second, to: secondFile)
    var confirmations = 0
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"),
                         confirmDiscard: { confirmations += 1; return false })
    #expect(state.openURL(firstFile))
    state.edit { $0.title = first.title }
    state.setTimeSignature(first.timeSignature)
    state.setPlaybackStartBar(first.metronomeSettings.loopStartBar)
    state.setPlaybackEndBar(first.metronomeSettings.loopEndBar)
    #expect(!state.hasUnsavedChanges)
    state.edit { $0.bpm = 150 }
    #expect(state.isDirty)
    state.edit { $0.bpm = first.bpm }
    state.lyricsDraft = "Черновик"
    #expect(state.hasUnsavedChanges)
    state.lyricsDraft = first.lyrics
    #expect(!state.hasUnsavedChanges)
    #expect(state.openURL(secondFile))
    #expect(confirmations == 0)
    #expect(state.project == second)
    #expect(!state.isDirty)
}

@Test(arguments: [false, true])
@MainActor func realEditsStillRequireConfirmationBeforeOpening(draftOnly: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let autosave = directory.appendingPathComponent("Autosave.visiorhythm")
    let file = directory.appendingPathComponent("Song.visiorhythm")
    let recovered = Project()
    let song = Project()
    try ProjectStore().save(recovered, to: autosave)
    try ProjectStore().save(song, to: file)
    var confirmations = 0
    var allowDiscard = false
    let state = AppState(autosaveURL: autosave, confirmDiscard: { confirmations += 1; return allowDiscard })
    if draftOnly { state.lyricsDraft = "Несохранённый черновик" }
    else { state.edit { $0.title = "Изменённое название" } }
    let before = state.project
    let draft = state.lyricsDraft
    #expect(!state.openURL(file))
    #expect(confirmations == 1)
    #expect(state.project == before)
    #expect(state.lyricsDraft == draft)
    #expect(state.fileURL == nil)
    #expect(state.hasUnsavedChanges)
    allowDiscard = true
    #expect(state.openURL(file))
    #expect(confirmations == 2)
    #expect(state.project == song)
    #expect(!state.hasUnsavedChanges)
}

@Test @MainActor func duplicateOpenEventsDoNotReloadEditedProject() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Song.visiorhythm")
    var song = Project()
    song.lyrics = "Война на фронте"
    song.lines = try LyricsEngine().parse(song.lyrics, signature: song.timeSignature)
    try ProjectStore().save(song, to: file)
    var confirmations = 0
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"),
                         confirmDiscard: { confirmations += 1; return false })
    #expect(state.openURL(file))
    state.fitLinesToPlaybackRange()
    state.lyricsDraft += "\nЧерновик"
    let before = state.project
    let draft = state.lyricsDraft
    let alias = directory.appendingPathComponent("unused/../Song.visiorhythm")
    #expect(state.openURL(alias))
    #expect(confirmations == 0)
    #expect(state.project == before)
    #expect(state.lyricsDraft == draft)
    #expect(state.hasUnsavedChanges)
    #expect(state.canResetLineFit)
}

@Test @MainActor func invalidFileDoesNotAskToSaveOrReplaceCurrentProject() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let invalid = directory.appendingPathComponent("Invalid.visiorhythm")
    try Data("{}".utf8).write(to: invalid)
    var confirmations = 0
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"),
                         confirmDiscard: { confirmations += 1; return false })
    state.lyricsDraft = "Война на фронте"
    #expect(state.applyLyrics())
    state.fitLinesToPlaybackRange()
    let before = state.project
    #expect(!state.openURL(invalid))
    #expect(confirmations == 0)
    #expect(state.project == before)
    #expect(state.errorMessage != nil)
    #expect(state.canResetLineFit)
    #expect(state.hasUnsavedChanges)
}

@Test @MainActor func savingEstablishesCleanBaselineForNextOpen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstFile = directory.appendingPathComponent("First.visiorhythm")
    let secondFile = directory.appendingPathComponent("Second.visiorhythm")
    let first = Project()
    let second = Project()
    try ProjectStore().save(first, to: firstFile)
    try ProjectStore().save(second, to: secondFile)
    var confirmations = 0
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"),
                         confirmDiscard: { confirmations += 1; return false })
    #expect(state.openURL(firstFile))
    state.lyricsDraft = "Война на фронте"
    #expect(state.save())
    #expect(try ProjectStore().load(from: firstFile) == state.project)
    #expect(!state.hasUnsavedChanges)
    #expect(state.openURL(secondFile))
    #expect(confirmations == 0)
    #expect(state.project == second)
    #expect(!state.hasUnsavedChanges)
}
