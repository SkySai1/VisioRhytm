import Foundation
import Testing
import VisioRhytmCore
@testable import VisioRhytm

@Test @MainActor func rangeSteppersChangeSinglePassSettingsAndCursor() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(autosaveURL: directory.appendingPathComponent("Autosave.visiorhythm"))
    state.edit { $0.metronomeSettings.loopEnabled = false }
    state.setPlaybackEndBar(2)
    #expect(state.project.metronomeSettings.loopEndBar == 2)
    #expect(RhythmEngine.timelineEndTicks(project: state.project) == 3840)
    state.setPlaybackStartBar(5)
    #expect(state.project.metronomeSettings.loopStartBar == 5)
    #expect(state.project.metronomeSettings.loopEndBar == 5)
    #expect(state.metronome.currentTicks() == 7680)
    state.setPlaybackEndBar(8)
    #expect(RhythmEngine.timelineEndTicks(project: state.project) == 15_360)
    state.setPlaybackEndBar(1)
    #expect(state.project.metronomeSettings.loopEndBar == 5)
    state.setTimeSignature(.init(6, 8))
    #expect(state.project.timeSignature == .init(6, 8))
    #expect(RhythmEngine.playbackRange(project: state.project) == 5760..<7200)
    state.returnToStart()
    #expect(state.metronome.currentTicks() == 5760)
}
