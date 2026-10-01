import Foundation
import Testing
@testable import VisioRhytmCore

private func expectedPattern(_ signature: TimeSignature) -> [MetricalStrength] {
    switch signature {
    case .init(4, 4): [.primary, .weak, .secondary, .weak]
    case .init(3, 4): [.primary, .weak, .weak]
    case .init(6, 8): [.primary, .weak, .weak, .secondary, .weak, .weak]
    case .init(12, 8): [.primary, .weak, .weak, .secondary, .weak, .weak,
                       .secondary, .weak, .weak, .secondary, .weak, .weak]
    default: []
    }
}

@Test(arguments: TimeSignature.supported)
func metricalPatternsRepeatInEveryBar(signature: TimeSignature) {
    let expected = expectedPattern(signature)
    #expect(RhythmEngine.beatStrengths(signature: signature) == expected)
    for bar in [0, 1, 7, 255] {
        for (beat, strength) in expected.enumerated() {
            let tick = Int64(bar) * signature.barTicks + Int64(beat) * signature.beatTicks
            #expect(RhythmEngine.metricalStrength(at: tick, signature: signature) == strength)
            #expect(RhythmEngine.metricalStrength(at: tick + signature.beatTicks / 2, signature: signature) == .subdivision)
        }
    }
}

@Test(arguments: TimeSignature.supported, Subdivision.allCases)
func changingGridPreservesBeatHierarchyAndExposesSubdivisions(signature: TimeSignature, subdivision: Subdivision) {
    let expected = expectedPattern(signature)
    let step = RhythmEngine.gridStep(signature: signature, subdivision: subdivision)
    var beats: [MetricalStrength] = []
    var subdivisionCount = 0
    for tick in stride(from: Int64(0), to: signature.barTicks, by: Int(step)) {
        let strength = RhythmEngine.metricalStrength(at: tick, signature: signature)
        if tick % signature.beatTicks == 0 { beats.append(strength) }
        else {
            subdivisionCount += 1
            #expect(strength == .subdivision)
        }
    }
    #expect(beats == expected)
    #expect(subdivisionCount == Int(signature.barTicks / step) - signature.numerator)
    // A quarter grid still includes all six or twelve eighth-note beats.
    #expect(step <= signature.beatTicks)
}

@Test func importedMetersDoNotInferSecondaryAccents() {
    for signature in [TimeSignature(4, 8), .init(9, 8), .init(5, 4), .init(7, 8)] {
        let expected: [MetricalStrength] = [.primary] + Array(repeating: .weak, count: signature.numerator - 1)
        #expect(RhythmEngine.beatStrengths(signature: signature) == expected)
        for (beat, strength) in expected.enumerated() {
            #expect(RhythmEngine.metricalStrength(at: Int64(beat) * signature.beatTicks, signature: signature) == strength)
        }
    }
}

@Test(arguments: TimeSignature.supported)
func audioAccentsAgreeWithMetricalSemantics(signature: TimeSignature) {
    let expected = expectedPattern(signature)
    for (beat, strength) in expected.enumerated() {
        let tick = Int64(beat) * signature.beatTicks
        let accent: ClickAccent = switch strength {
        case .primary: .primary
        case .secondary: .secondary
        case .weak: .regular
        case .subdivision: .subdivision
        }
        #expect(RhythmEngine.accent(at: tick, signature: signature) == accent)
        #expect(RhythmEngine.accent(at: tick + signature.beatTicks / 2, signature: signature) == .subdivision)
    }
}

@Test func metricalHintsCoverSilentPositionsWithoutChangingLyrics() throws {
    var project = Project()
    project.lyrics = "Война на фронте"
    project.lines = try LyricsEngine().parse(project.lyrics, signature: project.timeSignature)
    let originalLines = project.lines
    project.subdivision = .sixteenth
    project.metronomeSettings.loopStartBar = 5
    project.metronomeSettings.loopEndBar = 8
    project.metronomeSettings.previewSubdivision = false
    #expect(RhythmEngine.clickAccent(at: 0, project: project) == nil)
    #expect(RhythmEngine.metricalStrength(at: 0, signature: project.timeSignature) == .primary)
    #expect(RhythmEngine.metricalStrength(at: 960, signature: project.timeSignature) == .secondary)
    #expect(RhythmEngine.metricalStrength(at: 120, signature: project.timeSignature) == .subdivision)
    let rangeStart = RhythmEngine.playbackRange(project: project).lowerBound
    #expect(RhythmEngine.clickAccent(at: rangeStart + 120, project: project) == nil)
    project.metronomeSettings.previewSubdivision = true
    #expect(RhythmEngine.clickAccent(at: rangeStart + 120, project: project) == .subdivision)
    #expect(RhythmEngine.metricalStrength(at: rangeStart + 120, signature: project.timeSignature) == .subdivision)
    #expect(RhythmEngine.metricalStrength(at: 720, signature: .init(6, 8)) == .secondary)
    #expect(RhythmEngine.metricalStrength(at: 720, signature: .init(4, 4)) == .subdivision)
    #expect(project.lines == originalLines)
    #expect(try ProjectStore().decode(ProjectStore().encode(project)) == project)
}
