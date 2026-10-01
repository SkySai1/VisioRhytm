import Foundation

public struct MusicalPosition: Codable, Hashable, Sendable, Comparable {
    public var ticks: Int64
    public init(ticks: Int64 = 0) { self.ticks = ticks }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ticks < rhs.ticks }
}

public struct MusicalDuration: Codable, Hashable, Sendable {
    public var ticks: Int64
    public init(ticks: Int64) { self.ticks = ticks }
}

public struct TimeSignature: Codable, Hashable, Sendable, CustomStringConvertible {
    public var numerator: Int
    public var denominator: Int
    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
    public var description: String { "\(numerator)/\(denominator)" }
    public var beatTicks: Int64 { RhythmEngine.ppq * 4 / Int64(max(1, denominator)) }
    public var barTicks: Int64 { beatTicks * Int64(numerator) }
    public static let supported: [Self] = [.init(4, 4), .init(3, 4), .init(6, 8), .init(12, 8)]
}

public enum Subdivision: String, Codable, CaseIterable, Sendable {
    case quarter, eighth, sixteenth
    public var ticks: Int64 {
        switch self { case .quarter: 480; case .eighth: 240; case .sixteenth: 120 }
    }
    public var label: String {
        switch self { case .quarter: "1/4"; case .eighth: "1/8"; case .sixteenth: "1/16" }
    }
}

/// Metrical importance, independent of color, playback and syllable placement.
public enum MetricalStrength: String, Codable, CaseIterable, Sendable {
    case primary, secondary, weak, subdivision
}

public struct Syllable: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var index: Int
    public var wordIndex: Int
    /// Relative to the line start, never seconds or screen coordinates.
    public var position: MusicalPosition
    public var duration: MusicalDuration
    public var stress: Bool?
    public var durationWeight: Double
    public var manualBoundary: Bool
    public init(text: String, index: Int, wordIndex: Int, manualBoundary: Bool = false) {
        id = UUID()
        self.text = text
        self.index = index
        self.wordIndex = wordIndex
        position = .init()
        duration = .init(ticks: 1)
        stress = nil
        durationWeight = 1
        self.manualBoundary = manualBoundary
    }
}

public struct LyricsLine: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var originalText: String
    public var syllables: [Syllable]
    public var startPosition: MusicalPosition
    public var rhythmicLength: MusicalDuration
    /// Words separated with spaces, syllables inside a word separated with |.
    public var manualOverrides: String?
    public init(text: String, length: Int64) {
        id = UUID()
        originalText = text
        syllables = []
        startPosition = .init()
        rhythmicLength = .init(ticks: length)
    }
    public var endTicks: Int64 { startPosition.ticks + rhythmicLength.ticks }
    public var renderedWords: [String] {
        var words: [String] = []
        for syllable in syllables {
            if syllable.wordIndex == words.count { words.append(syllable.text) }
            else if syllable.wordIndex >= 0 && syllable.wordIndex < words.count { words[syllable.wordIndex] += syllable.text }
        }
        return words
    }
    public var renderedText: String { renderedWords.joined(separator: " ") }
}

public struct MetronomeSettings: Codable, Hashable, Sendable {
    public var volume: Double = 0.6
    public var previewSubdivision: Bool = false
    public var loopEnabled: Bool = true
    public var loopStartBar: Int = 1
    public var loopEndBar: Int = 4
    public init() {}
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public var version: Int = currentVersion
    public var id: UUID = UUID()
    public var title: String = "Без названия"
    /// Quarter notes per minute, including in compound meters.
    public var bpm: Double = 120
    public var timeSignature: TimeSignature = .init(4, 4)
    public var subdivision: Subdivision = .eighth
    public var lyrics: String = ""
    public var lines: [LyricsLine] = []
    public var metronomeSettings: MetronomeSettings = .init()
    public init() {}
}
