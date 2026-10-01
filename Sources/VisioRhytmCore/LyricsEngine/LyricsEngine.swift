import Foundation

public protocol SyllabificationService: Sendable {
    func syllabify(_ word: String) -> [String]
}

/// A deliberately transparent heuristic, with no dictionaries or network access.
public struct RussianSyllabifier: SyllabificationService {
    public init() {}
    public func syllabify(_ word: String) -> [String] {
        let chars = Array(word)
        let vowels = Set("аеёиоуыэюяАЕЁИОУЫЭЮЯaeiouyAEIOUY")
        let nuclei = chars.indices.filter { vowels.contains(chars[$0]) }
        guard nuclei.count > 1 else { return word.isEmpty ? [] : [word] }
        let sonorants = Set("йЙлЛмМнНрРьЬъЪ")
        var boundaries = [0]
        for pair in zip(nuclei, nuclei.dropFirst()) {
            let gap = pair.1 - pair.0 - 1
            var boundary = pair.0 + 1
            if gap > 1 && sonorants.contains(chars[pair.0 + 1]) { boundary += 1 }
            if gap > 2 && boundary < pair.1 && (chars[boundary] == "ь" || chars[boundary] == "ъ") { boundary += 1 }
            boundaries.append(boundary)
        }
        boundaries.append(chars.count)
        return zip(boundaries, boundaries.dropFirst()).map { String(chars[$0..<$1]) }
    }
}

public enum LyricsError: LocalizedError {
    case differentWords, emptySyllable, tooMuchText
    public var errorDescription: String? {
        switch self {
        case .differentWords: "Ручное разбиение должно сохранять слова и знаки исходной строки. Используйте | только для границ слогов."
        case .emptySyllable: "Пустой слог недопустим. Уберите повторяющиеся | и | на краях слова."
        case .tooMuchText: "Допустимо до 500 строк, 100 000 символов и 2 000 слогов в строке."
        }
    }
}

public struct LyricsEngine: Sendable {
    private let syllabifier: any SyllabificationService
    public init(syllabifier: any SyllabificationService = RussianSyllabifier()) { self.syllabifier = syllabifier }
    public func parse(_ lyrics: String, signature: TimeSignature) throws -> [LyricsLine] {
        let texts = lyrics.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lyrics.count <= 100_000, texts.count <= 500 else { throw LyricsError.tooMuchText }
        return try texts.map { text in
            var line = LyricsLine(text: text, length: signature.barTicks * 2)
            try rebuild(&line)
            return line
        }
    }
    public func rebuild(_ line: inout LyricsLine, manual: String? = nil) throws {
        let words = line.originalText.split(whereSeparator: \.isWhitespace).map(String.init)
        let pieces: [[String]]
        if let manual {
            let entries = manual.split(whereSeparator: \.isWhitespace).map(String.init)
            guard entries.count == words.count else { throw LyricsError.differentWords }
            pieces = entries.map { $0.components(separatedBy: "|") }
            guard pieces.allSatisfy({ $0.allSatisfy { !$0.isEmpty } }) else { throw LyricsError.emptySyllable }
            guard zip(pieces, words).allSatisfy({ $0.joined() == $1 }) else { throw LyricsError.differentWords }
        } else {
            pieces = words.map(syllabifier.syllabify)
        }
        guard pieces.reduce(0, { $0 + $1.count }) <= 2_000, line.originalText.count <= 100_000 else { throw LyricsError.tooMuchText }
        var syllables: [Syllable] = []
        for (wordIndex, chunks) in pieces.enumerated() {
            for text in chunks {
                syllables.append(.init(text: text, index: syllables.count, wordIndex: wordIndex, manualBoundary: manual != nil))
            }
        }
        line.manualOverrides = manual
        line.syllables = syllables
        layout(&line)
    }
    public func layout(_ line: inout LyricsLine) {
        let count = line.syllables.count
        guard count > 0 else { return }
        line.rhythmicLength.ticks = max(Int64(count), line.rhythmicLength.ticks)
        for i in line.syllables.indices {
            let start = Int64(i) * line.rhythmicLength.ticks / Int64(count)
            let end = Int64(i + 1) * line.rhythmicLength.ticks / Int64(count)
            line.syllables[i].position.ticks = start
            line.syllables[i].duration.ticks = end - start
        }
    }
    public func manualText(for line: LyricsLine) -> String {
        var words: [String] = []
        for syllable in line.syllables {
            if syllable.wordIndex >= words.count { words.append(syllable.text) }
            else { words[syllable.wordIndex] += "|" + syllable.text }
        }
        return words.joined(separator: " ")
    }
}
