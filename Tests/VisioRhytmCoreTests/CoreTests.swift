import Foundation
import Testing
@testable import VisioRhytmCore

private func example() throws -> Project {
    var project = Project()
    project.lyrics = "Война на невидимом фронте\nГде враг растворяется в сети"
    project.lines = try LyricsEngine().parse(project.lyrics, signature: project.timeSignature)
    return project
}

@Test func musicalUnitsAndMeters() {
    #expect(RhythmEngine.ppq == 480)
    #expect(TimeSignature(4, 4).barTicks == 1920)
    #expect(TimeSignature(3, 4).barTicks == 1440)
    #expect(TimeSignature(6, 8).barTicks == 1440)
    #expect(TimeSignature(12, 8).barTicks == 2880)
    #expect(Subdivision.allCases.map(\.ticks) == [480, 240, 120])
    #expect(RhythmEngine.address(ticks: 1680, signature: .init(6, 8)).bar == 2)
    #expect(RhythmEngine.address(ticks: 1680, signature: .init(6, 8)).beat == 2)
}

@Test func tempoConversionRoundTrips() {
    for bpm in [40.0, 60, 120, 137, 240] {
        #expect(abs(RhythmEngine.ticks(seconds: RhythmEngine.seconds(ticks: 3840, bpm: bpm), bpm: bpm) - 3840) < 1e-8)
    }
    #expect(RhythmEngine.seconds(ticks: 3840, bpm: 60) == 8)
    #expect(RhythmEngine.seconds(ticks: 3840, bpm: 120) == 4)
}

@Test func changingTempoAndMeterPreservesLayout() throws {
    var project = try example()
    let lines = project.lines
    project.bpm = 240
    project.timeSignature = .init(6, 8)
    project.subdivision = .sixteenth
    #expect(project.lines == lines)
    try ProjectStore().validate(project)
}

@Test func russianHeuristicPreservesAllCharacters() {
    let service = RussianSyllabifier()
    #expect(service.syllabify("невидимом") == ["не", "ви", "ди", "мом"])
    #expect(service.syllabify("Война") == ["Вой", "на"])
    for word in ["фронте", "строим", "защиту", "в", "мгла", "объём", "сегодня!", "русский", "AI", "поёт", "Чтоб", "123", "", "Ёлка"] {
        #expect(service.syllabify(word).joined() == word)
    }
    #expect(service.syllabify("в") == ["в"])
}

@Test func parserSkipsBlankLinesAndHandlesCRLF() throws {
    let lines = try LyricsEngine().parse("\r\n  Первая строка\r\n\r\nВторая строка  \n", signature: .init(4, 4))
    #expect(lines.map(\.originalText) == ["Первая строка", "Вторая строка"])
    #expect(lines.allSatisfy { $0.startPosition.ticks == 0 && $0.rhythmicLength.ticks == 3840 })
}

@Test func automaticLayoutFillsExactLengthWithoutOverlap() throws {
    var line = try #require(example().lines.first)
    line.rhythmicLength.ticks = 1921
    LyricsEngine().layout(&line)
    #expect(line.syllables.first?.position.ticks == 0)
    let last = try #require(line.syllables.last)
    #expect(last.position.ticks + last.duration.ticks == 1921)
    for pair in zip(line.syllables, line.syllables.dropFirst()) {
        #expect(pair.0.position.ticks + pair.0.duration.ticks == pair.1.position.ticks)
        #expect(pair.0.duration.ticks > 0)
    }
}

@Test func densityIsDerivedAndDoesNotChangeText() throws {
    var line = try #require(example().lines.first)
    let text = line.originalText
    let chunks = line.syllables.map(\.text)
    let signature = TimeSignature(4, 4)
    let oldDensity = RhythmEngine.density(for: line, signature: signature)
    line.rhythmicLength.ticks /= 2
    LyricsEngine().layout(&line)
    #expect(RhythmEngine.density(for: line, signature: signature) == oldDensity * 2)
    #expect(line.originalText == text && line.syllables.map(\.text) == chunks)
    let length = RhythmEngine.length(syllableCount: 10, density: 1.25, signature: signature)
    #expect(length == 3840)
}

@Test func manualBoundariesKeepOriginalText() throws {
    var line = LyricsLine(text: "Невидимом фронте", length: 3840)
    try LyricsEngine().rebuild(&line, manual: "Не|видимом фрон|те")
    #expect(line.syllables.map(\.text) == ["Не", "видимом", "фрон", "те"])
    #expect(line.originalText == "Невидимом фронте")
    #expect(line.syllables.allSatisfy { $0.manualBoundary })
    #expect(LyricsEngine().manualText(for: line) == "Не|видимом фрон|те")
    try LyricsEngine().rebuild(&line)
    #expect(line.manualOverrides == nil)
    #expect(line.syllables.allSatisfy { !$0.manualBoundary })
}

@Test func invalidManualBoundariesAreRejected() throws {
    var line = LyricsLine(text: "невидимом фронте", length: 3840)
    #expect(throws: LyricsError.self) { try LyricsEngine().rebuild(&line, manual: "не||видимом фронте") }
    #expect(throws: LyricsError.self) { try LyricsEngine().rebuild(&line, manual: "не|видимый фронте") }
    #expect(throws: LyricsError.self) { try LyricsEngine().rebuild(&line, manual: "невидимомфронте") }
}

@Test func projectRoundTripIncludesManualPositions() throws {
    var project = try example()
    try LyricsEngine().rebuild(&project.lines[0], manual: "Вой|на на не|ви|ди|мом фрон|те")
    project.lines[0].startPosition.ticks = 480
    project.lines[0].syllables[0].duration.ticks = 100
    let data = try ProjectStore().encode(project)
    #expect(try ProjectStore().decode(data) == project)
}

@Test func atomicSaveAndLoad() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Test.visiorhythm")
    var project = try example()
    try ProjectStore().save(project, to: url)
    project.bpm = 140
    try ProjectStore().save(project, to: url)
    #expect(try ProjectStore().load(from: url) == project)
}

@Test func futureAndMalformedProjectsAreRejected() throws {
    #expect(throws: ProjectError.self) { try ProjectStore().decode(Data("{\"version\":2}".utf8)) }
    #expect(throws: (any Error).self) { try ProjectStore().decode(Data("not json".utf8)) }
    var project = try example()
    project.bpm = 0
    #expect(throws: ProjectError.self) { try ProjectStore().encode(project) }
    project.bpm = 120
    project.timeSignature.denominator = 0
    #expect(throws: ProjectError.self) { try ProjectStore().encode(project) }
    project.timeSignature = .init(4, 4)
    project.lines[0].startPosition.ticks = Int64.max
    project.lines[0].rhythmicLength.ticks = Int64.max
    #expect(throws: ProjectError.self) { try ProjectStore().encode(project) }
}

@Test func invalidLoopAndAlteredSourceAreRejected() throws {
    var project = try example()
    project.metronomeSettings.loopStartBar = 5
    project.metronomeSettings.loopEndBar = 2
    #expect(throws: ProjectError.self) { try ProjectStore().validate(project) }
    project.metronomeSettings.loopEndBar = 8
    project.lines[0].syllables[0].text = "другой текст"
    #expect(throws: ProjectError.self) { try ProjectStore().validate(project) }
}

@Test func accentsAndCompoundMeter() {
    #expect(RhythmEngine.accent(at: 0, signature: .init(6, 8)) == .primary)
    #expect(RhythmEngine.accent(at: 720, signature: .init(6, 8)) == .secondary)
    #expect(RhythmEngine.accent(at: 240, signature: .init(6, 8)) == .regular)
    #expect(RhythmEngine.accent(at: 120, signature: .init(6, 8)) == .subdivision)
    #expect(RhythmEngine.clickStep(signature: .init(6, 8), subdivision: .quarter, preview: true) == 240)
    #expect(RhythmEngine.clickStep(signature: .init(4, 4), subdivision: .sixteenth, preview: true) == 120)
    #expect(RhythmEngine.clickStep(signature: .init(4, 4), subdivision: .sixteenth, preview: false) == 480)
}

@Test func tenMinuteSampleClockHasNoAccumulatedDrift() {
    for rate in [44_100.0, 48_000.0, 96_000.0] {
        for bpm in [40.0, 137.0, 240.0] {
            var project = Project(); project.bpm = bpm; project.metronomeSettings.loopEnabled = false
            let plan = PlaybackPlan(project: project, startTicks: 0, sampleRate: rate)
            for seconds in stride(from: 0.0, through: 600.0, by: 0.371) {
                let frame = (seconds * rate).rounded()
                let actual = plan.position(frame: frame)
                let expected = RhythmEngine.ticks(seconds: frame / rate, bpm: bpm)
                #expect(abs(actual - expected) < 1e-7)
            }
        }
    }
}

@Test func loopBarsFiveToEightAndResume() {
    var project = Project()
    project.bpm = 137
    project.metronomeSettings.loopStartBar = 5
    project.metronomeSettings.loopEndBar = 8
    let plan = PlaybackPlan(project: project, startTicks: 0, sampleRate: 48_000)
    #expect(plan.startTicks == 7680)
    let loopFrames = Double(7680) / plan.ticksPerFrame
    #expect(abs(plan.position(frame: loopFrames * 1000 + 100) - (7680 + 100 * plan.ticksPerFrame)) < 1e-6)
    let resumed = PlaybackPlan(project: project, startTicks: 8000, sampleRate: 48_000)
    #expect(resumed.position(frame: 0) == 8000)
}

@Test func synthesizedClickIsFiniteAndSilentBetweenOnsets() {
    var project = Project(); project.metronomeSettings.loopEnabled = false
    let plan = PlaybackPlan(project: project, startTicks: 0, sampleRate: 48_000)
    let click = (0..<1100).map { plan.sample(frame: Int64($0)) }
    #expect(click.allSatisfy { $0.isFinite })
    #expect(click.contains { abs($0) > 0.1 })
    #expect(plan.sample(frame: 12_000) == 0)
    #expect(abs(plan.sample(frame: 24_010)) > 0)
    let mutedProject: Project = { var p = project; p.metronomeSettings.volume = 0; return p }()
    #expect(PlaybackPlan(project: mutedProject, startTicks: 0, sampleRate: 48_000).sample(frame: 10) == 0)
}

@Test func resumingDoesNotPlayTailOfPreviousClick() {
    var project = Project(); project.metronomeSettings.loopEnabled = false
    let plan = PlaybackPlan(project: project, startTicks: 2, sampleRate: 48_000)
    #expect((0..<1000).allSatisfy { plan.sample(frame: Int64($0)) == 0 })
}

@Test func parserBoundsResources() {
    #expect(throws: LyricsError.self) { try LyricsEngine().parse(String(repeating: "строка\n", count: 501), signature: .init(4, 4)) }
}
