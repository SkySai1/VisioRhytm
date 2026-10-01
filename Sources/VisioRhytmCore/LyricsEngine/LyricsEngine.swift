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
        case .differentWords: "Ручное разбиение должно сохранять слова и знаки вне [] и (). Используйте | только для границ слогов."
        case .emptySyllable: "Пустой слог недопустим. Уберите повторяющиеся | и | на краях слова."
        case .tooMuchText: "Допустимо до 500 строк, 100 000 символов и 2 000 слогов в строке."
        }
    }
}

public struct LyricsSourceLine: Sendable {
    public let originalText: String
    public let canvasText: String
    public let sourceLineIndex: Int
    public let blankLinesBefore: Int
}

public struct LyricsEngine: Sendable {
    private let syllabifier: any SyllabificationService
    public init(syllabifier: any SyllabificationService = RussianSyllabifier()) { self.syllabifier = syllabifier }
    /// Remove balanced annotations, retaining line breaks and word separation.
    /// Unclosed delimiters remain literal text so an unfinished edit cannot hide a verse.
    public func canvasText(_ text: String) -> String {
        let characters = Array(text)
        var openings: [(Character, Int)] = []
        var changes = [Int](repeating: 0, count: characters.count + 1)
        for (index, character) in characters.enumerated() {
            if character == "[" || character == "(" { openings.append((character, index)) }
            else if let last = openings.last,
                    (character == "]" && last.0 == "[") || (character == ")" && last.0 == "(") {
                openings.removeLast()
                changes[last.1] += 1
                changes[index + 1] -= 1
            }
        }
        var depth = 0
        var result = ""
        var wasIgnored = false
        for (index, character) in characters.enumerated() {
            depth += changes[index]
            if depth == 0 || character.isNewline {
                result.append(character)
                wasIgnored = false
            } else if !wasIgnored {
                result.append(" ")
                wasIgnored = true
            }
        }
        return result
    }
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    public func sourceLines(_ lyrics: String) -> [LyricsSourceLine] {
        let source = normalized(lyrics)
        let originals = source.components(separatedBy: "\n")
        let visible = canvasText(source).components(separatedBy: "\n")
        var blankCount = 0
        var hasVisibleLine = false
        return originals.indices.map {
            let original = originals[$0].trimmingCharacters(in: .whitespaces)
            let canvas = visible[$0].trimmingCharacters(in: .whitespaces)
            let gap = !canvas.isEmpty && hasVisibleLine ? blankCount : 0
            if !canvas.isEmpty { hasVisibleLine = true; blankCount = 0 }
            else if original.isEmpty && hasVisibleLine { blankCount += 1 }
            return LyricsSourceLine(originalText: original, canvasText: canvas, sourceLineIndex: $0, blankLinesBefore: gap)
        }
    }
    public func canvasLines(_ lyrics: String) -> [LyricsSourceLine] {
        sourceLines(lyrics).filter { !$0.canvasText.isEmpty }
    }
    public func replacingSourceLine(in lyrics: String, at index: Int, with text: String) -> String {
        var lines = normalized(lyrics).components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return lyrics }
        lines[index] = text
        return lines.joined(separator: "\n")
    }
    public func parse(_ lyrics: String, signature: TimeSignature, preserving existing: [LyricsLine] = [], preservingEdits: Bool = false) throws -> [LyricsLine] {
        guard lyrics.count <= 100_000 else { throw LyricsError.tooMuchText }
        let sources = canvasLines(lyrics)
        guard sources.count <= 500 else { throw LyricsError.tooMuchText }
        var remaining = existing
        let editedMatches = preservingEdits ? matchEditedLines(sources, existing: existing) : [:]
        return try sources.enumerated().map { offset, source in
            var line = LyricsLine(text: source.originalText, length: signature.barTicks * 2)
            if preservingEdits, let oldIndex = editedMatches[offset] {
                line = existing[oldIndex]
                line.originalText = source.originalText
                if line.renderedWords == source.canvasText.split(whereSeparator: \.isWhitespace).map(String.init) { return line }
            } else if !preservingEdits, let index = remaining.firstIndex(where: { $0.originalText == source.originalText }) {
                line = remaining.remove(at: index)
                if line.renderedWords == source.canvasText.split(whereSeparator: \.isWhitespace).map(String.init) { return line }
            }
            if let manual = line.manualOverrides,
               (try? rebuild(&line, manual: canvasText(manual), textForCanvas: source.canvasText)) != nil {
                return line
            }
            try rebuild(&line, textForCanvas: source.canvasText)
            return line
        }
    }
    /// Unchanged lines anchor each edit region. Replacements retain their musical length;
    /// inserted lines receive defaults, and moved exact matches retain their identity.
    private func matchEditedLines(_ sources: [LyricsSourceLine], existing: [LyricsLine]) -> [Int: Int] {
        let difference = sources.map(\.originalText).difference(from: existing.map(\.originalText)).inferringMoves()
        var removed = Set<Int>(), inserted = Set<Int>(), result: [Int: Int] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, let old):
                inserted.insert(offset)
                if let old { result[offset] = old }
            }
        }
        let oldUnchanged = existing.indices.filter { !removed.contains($0) }
        let newUnchanged = sources.indices.filter { !inserted.contains($0) }
        let anchors = Array(zip(newUnchanged, oldUnchanged)) + [(sources.count, existing.count)]
        var newStart = 0, oldStart = 0
        let moved = Set(result.values)
        for (newEnd, oldEnd) in anchors {
            let oldEdits = (oldStart..<oldEnd).filter { !moved.contains($0) }
            let newEdits = (newStart..<newEnd).filter { result[$0] == nil }
            for (new, old) in zip(newEdits, oldEdits) { result[new] = old }
            if newEnd < sources.count { result[newEnd] = oldEnd }
            newStart = newEnd + 1; oldStart = oldEnd + 1
        }
        return result
    }
    public func rebuild(_ line: inout LyricsLine, manual: String? = nil, textForCanvas: String? = nil) throws {
        let words = (textForCanvas ?? canvasText(line.originalText)).split(whereSeparator: \.isWhitespace).map(String.init)
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
