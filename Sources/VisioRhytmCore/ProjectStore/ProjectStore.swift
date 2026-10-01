import Foundation

public enum ProjectError: LocalizedError {
    case unsupportedVersion(Int), invalid(String), oversized
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Версия проекта \(version) не поддерживается. Приложение читает версию 1."
        case .invalid(let reason): "Некорректный проект: \(reason)"
        case .oversized: "Размер файла проекта превышает 20 МБ."
        }
    }
}

public struct ProjectStore: Sendable {
    public init() {}
    public func encode(_ project: Project) throws -> Data {
        try validate(project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(project)
        guard data.count <= 20_000_000 else { throw ProjectError.oversized }
        return data
    }
    public func decode(_ data: Data) throws -> Project {
        guard data.count <= 20_000_000 else { throw ProjectError.oversized }
        // Inspect the envelope before decoding fields of a potentially newer schema.
        struct Envelope: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Envelope.self, from: data).version
        guard version == Project.currentVersion else { throw ProjectError.unsupportedVersion(version) }
        let project = try JSONDecoder().decode(Project.self, from: data)
        try validate(project)
        return project
    }
    public func load(from url: URL) throws -> Project {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw ProjectError.oversized }
        return try decode(Data(contentsOf: url))
    }
    public func save(_ project: Project, to url: URL) throws {
        let data = try encode(project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    public func validate(_ project: Project) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ProjectError.invalid(reason) }
        }
        guard project.version == Project.currentVersion else { throw ProjectError.unsupportedVersion(project.version) }
        try require(project.bpm.isFinite && (40...240).contains(project.bpm), "BPM должен быть от 40 до 240")
        let signature = project.timeSignature
        try require((1...32).contains(signature.numerator) && [2, 4, 8, 16].contains(signature.denominator), "недопустимый музыкальный размер")
        let settings = project.metronomeSettings
        try require(settings.volume.isFinite && (0...1).contains(settings.volume), "недопустимая громкость")
        try require(settings.loopStartBar >= 1 && settings.loopEndBar >= settings.loopStartBar && settings.loopEndBar <= 256, "диапазон цикла должен быть в пределах 1–256 тактов")
        try require(project.lyrics.count <= 100_000 && project.lines.count <= 500 && project.title.count <= 500, "слишком большой текст")
        try require(Set(project.lines.map(\.id)).count == project.lines.count, "повторяющиеся идентификаторы строк")
        var allIDs = Set<UUID>()
        for line in project.lines {
            try require(!line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "пустая строка")
            try require((0...1_000_000).contains(line.startPosition.ticks) && (1...1_000_000).contains(line.rhythmicLength.ticks), "строка выходит за допустимую длину")
            try require(line.endTicks <= 1_000_000, "строка выходит за допустимую длину")
            try require(!line.syllables.isEmpty && line.syllables.count <= 2_000, "недопустимое количество слогов")
            var words: [String] = []
            for (index, syllable) in line.syllables.enumerated() {
                try require(allIDs.insert(syllable.id).inserted, "повторяющиеся идентификаторы слогов")
                try require(syllable.index == index && !syllable.text.isEmpty, "некорректный слог")
                try require(syllable.position.ticks >= 0 && syllable.duration.ticks > 0 && syllable.position.ticks <= line.rhythmicLength.ticks - syllable.duration.ticks, "слог выходит за границы строки")
                try require(syllable.durationWeight.isFinite && syllable.durationWeight > 0, "некорректный вес длительности")
                try require(syllable.wordIndex >= 0 && syllable.wordIndex <= words.count, "некорректный индекс слова")
                if syllable.wordIndex == words.count { words.append(syllable.text) }
                else {
                    try require(syllable.wordIndex == words.count - 1, "нарушен порядок слов")
                    words[syllable.wordIndex] += syllable.text
                }
            }
            try require(words == line.originalText.split(whereSeparator: \.isWhitespace).map(String.init), "слоги не соответствуют исходному тексту")
            if let manual = line.manualOverrides {
                var rebuilt = line
                try LyricsEngine().rebuild(&rebuilt, manual: manual)
                try require(rebuilt.syllables.map(\.text) == line.syllables.map(\.text), "ручные границы не соответствуют слогам")
            }
        }
        let originalLines = project.lyrics.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try require(originalLines == project.lines.map(\.originalText), "строки не соответствуют lyrics")
    }
}
