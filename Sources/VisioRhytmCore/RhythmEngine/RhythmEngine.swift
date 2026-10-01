import Foundation

public enum DensityCategory: String, Sendable {
    case sparse = "Свободно", moderate = "Умеренно", dense = "Плотно", veryDense = "Очень плотно"
}

public enum ClickAccent: Sendable {
    case primary, secondary, regular, subdivision
    public var frequency: Double {
        switch self { case .primary: 1760; case .secondary: 1320; case .regular: 880; case .subdivision: 660 }
    }
    public var gain: Double {
        switch self { case .primary: 0.8; case .secondary: 0.65; case .regular: 0.5; case .subdivision: 0.28 }
    }
}

public enum RhythmEngine {
    public static let ppq: Int64 = 480
    public static func playbackRange(project: Project) -> Range<Int64> {
        let bar = project.timeSignature.barTicks
        return Int64(project.metronomeSettings.loopStartBar - 1) * bar ..< Int64(project.metronomeSettings.loopEndBar) * bar
    }
    /// Canvas includes the selected playback range and all existing lyric positions.
    public static func timelineEndTicks(project: Project) -> Int64 {
        let bar = project.timeSignature.barTicks
        let end = max(project.lines.map(\.endTicks).max() ?? 0, playbackRange(project: project).upperBound)
        return ((end + bar - 1) / bar) * bar
    }
    public static func seconds(ticks: Double, bpm: Double) -> Double {
        ticks / Double(ppq) * 60 / bpm
    }
    public static func ticks(seconds: Double, bpm: Double) -> Double {
        seconds * bpm / 60 * Double(ppq)
    }
    public static func bars(for line: LyricsLine, signature: TimeSignature) -> Double {
        Double(line.rhythmicLength.ticks) / Double(signature.barTicks)
    }
    public static func density(for line: LyricsLine, signature: TimeSignature) -> Double {
        Double(line.syllables.count) * Double(signature.beatTicks) / Double(max(1, line.rhythmicLength.ticks))
    }
    public static func category(_ density: Double) -> DensityCategory {
        if density < 1 { return .sparse }
        if density < 2 { return .moderate }
        if density < 3 { return .dense }
        return .veryDense
    }
    public static func length(syllableCount: Int, density: Double, signature: TimeSignature) -> Int64 {
        max(Int64(max(1, syllableCount)), Int64((Double(max(1, syllableCount)) * Double(signature.beatTicks) / max(0.01, density)).rounded()))
    }
    public static func address(ticks: Int64, signature: TimeSignature) -> (bar: Int, beat: Int) {
        let ticks = max(0, ticks)
        return (Int(ticks / signature.barTicks) + 1, Int((ticks % signature.barTicks) / signature.beatTicks) + 1)
    }
    public static func accent(at ticks: Int64, signature: TimeSignature) -> ClickAccent {
        let local = ticks % signature.barTicks
        if local == 0 { return .primary }
        if local % signature.beatTicks != 0 { return .subdivision }
        let beat = local / signature.beatTicks
        if signature.denominator == 8 && signature.numerator % 3 == 0 && beat % 3 == 0 { return .secondary }
        if signature.numerator == 4 && beat == 2 { return .secondary }
        return .regular
    }
    /// The beat always remains audible even when the visual grid is coarser.
    public static func clickStep(signature: TimeSignature, subdivision: Subdivision, preview: Bool) -> Int64 {
        preview ? min(signature.beatTicks, subdivision.ticks) : signature.beatTicks
    }
    /// Onsets shown by Canvas use the same step and accents as the audio plan.
    public static func clickAccent(at ticks: Int64, project: Project) -> ClickAccent? {
        guard playbackRange(project: project).contains(ticks) else { return nil }
        let step = clickStep(signature: project.timeSignature, subdivision: project.subdivision,
                             preview: project.metronomeSettings.previewSubdivision)
        guard ticks % step == 0 else { return nil }
        return accent(at: ticks, signature: project.timeSignature)
    }
    public static func gridLabel(ticks: Int64, signature: TimeSignature, subdivision: Subdivision) -> String {
        let local = ticks % signature.barTicks
        let fraction = local % signature.beatTicks
        if fraction == 0 { return String(local / signature.beatTicks + 1) }
        if signature.denominator == 4 && subdivision == .sixteenth {
            return ["", "e", "&", "a"][Int(fraction / 120)]
        }
        return "&"
    }
}

/// Pure sample-clock transport, shared by audio synthesis and UI clock conversion.
/// Absolute sample positions prevent error accumulation from rounded click intervals.
public struct PlaybackPlan: Sendable {
    public let bpm: Double
    public let signature: TimeSignature
    public let stepTicks: Int64
    public let startTicks: Int64
    public let loopRange: Range<Int64>?
    public let endTicks: Int64?
    public let sampleRate: Double
    public let volume: Double
    public init(project: Project, startTicks: Int64, sampleRate: Double) {
        bpm = project.bpm
        signature = project.timeSignature
        stepTicks = RhythmEngine.clickStep(signature: signature, subdivision: project.subdivision, preview: project.metronomeSettings.previewSubdivision)
        let range = RhythmEngine.playbackRange(project: project)
        self.startTicks = startTicks >= range.lowerBound && startTicks < range.upperBound ? startTicks : range.lowerBound
        if project.metronomeSettings.loopEnabled {
            loopRange = range
            endTicks = nil
        } else {
            loopRange = nil
            endTicks = range.upperBound
        }
        self.sampleRate = sampleRate
        volume = project.metronomeSettings.volume
    }
    public var ticksPerFrame: Double { bpm * Double(RhythmEngine.ppq) / (60 * sampleRate) }
    public func isFinished(frame: Double) -> Bool {
        guard let endTicks else { return false }
        return Double(startTicks) + max(0, frame) * ticksPerFrame >= Double(endTicks)
    }
    public func position(frame: Double) -> Double {
        let absolute = Double(startTicks) + max(0, frame) * ticksPerFrame
        guard let range = loopRange else { return min(absolute, Double(endTicks ?? startTicks)) }
        let length = Double(range.count)
        return Double(range.lowerBound) + (absolute - Double(range.lowerBound)).truncatingRemainder(dividingBy: length)
    }
    public func sample(frame: Int64) -> Float {
        guard !isFinished(frame: Double(frame)) else { return 0 }
        let tick = position(frame: Double(frame))
        let clickTick = Int64(floor((tick + 1e-8) / Double(stepTicks))) * stepTicks
        // Resuming midway through a click must not invent a new onset.
        let initialOffset = startTicks % stepTicks
        if initialOffset != 0 && Double(frame) * ticksPerFrame < Double(stepTicks - initialOffset) { return 0 }
        let age = max(0, (tick - Double(clickTick)) / ticksPerFrame)
        let duration = sampleRate * 0.022
        guard age < duration else { return 0 }
        let accent = RhythmEngine.accent(at: clickTick, signature: signature)
        let envelope = exp(-age / (sampleRate * 0.004)) * min(1, age / (sampleRate * 0.0005))
        return Float(sin(2 * .pi * accent.frequency * age / sampleRate) * envelope * accent.gain * volume)
    }
}
