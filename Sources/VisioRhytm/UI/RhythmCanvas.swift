import SwiftUI
import VisioRhytmCore

struct RhythmCanvas: View {
    let state: AppState
    static let rowHeight: CGFloat = 104
    static let rulerHeight: CGFloat = 64
    private let controlsWidth: CGFloat = 260
    var body: some View {
        GeometryReader { geometry in
            let signature = state.project.timeSignature
            let end = max(state.project.lines.map(\.endTicks).max() ?? 0,
                          Int64(state.project.metronomeSettings.loopEnabled ? state.project.metronomeSettings.loopEndBar : 4) * signature.barTicks)
            let bars = max(4, Int(ceil(Double(end) / Double(signature.barTicks))))
            let ticks = Int64(bars) * signature.barTicks
            let scale = 96 * state.zoom / Double(RhythmEngine.ppq)
            let width = max(geometry.size.width - controlsWidth, Double(ticks) * scale + 30)
            let height = Self.rulerHeight + Double(max(1, state.project.lines.count)) * Self.rowHeight
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("СТРОКИ").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("Такты · плотность · слоги / долю").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: Self.rulerHeight)
                        ForEach(Array(state.project.lines.enumerated()), id: \.element.id) { number, line in
                            LineControls(state: state, line: line, number: number + 1)
                        }
                    }.frame(width: controlsWidth)
                    Divider()
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, size in
                                drawGrid(context: &context, size: size, signature: signature, subdivision: state.project.subdivision, ticks: ticks, scale: scale)
                            }
                            VStack(spacing: 0) {
                                Color.clear.frame(height: Self.rulerHeight)
                                if state.project.lines.isEmpty {
                                    Text("Вставьте текст слева и нажмите «Разместить строки».")
                                        .foregroundStyle(.secondary).frame(width: min(width, 600), height: Self.rowHeight)
                                }
                                ForEach(Array(state.project.lines.enumerated()), id: \.element.id) { number, line in
                                    LyricsTrack(line: line, number: number + 1, signature: signature, scale: scale)
                                        .frame(width: width, height: Self.rowHeight)
                                        .onTapGesture { state.selectedLineID = line.id }
                                        .help(line.originalText + "\nНажмите для редактирования текста и слогов.")
                                }
                            }
                            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !state.metronome.isPlaying)) { _ in
                                let position = state.metronome.currentTicks()
                                Canvas { context, size in
                                    guard position <= Double(ticks) else { return }
                                    let columnTicks = min(signature.beatTicks, state.project.subdivision.ticks)
                                    let column = floor(position / Double(columnTicks)) * Double(columnTicks)
                                    let rect = CGRect(x: column * scale, y: Self.rulerHeight, width: Double(columnTicks) * scale, height: size.height - Self.rulerHeight)
                                    context.fill(Path(rect), with: .color(.teal.opacity(state.metronome.isPlaying ? 0.12 : 0.04)))
                                    var line = Path()
                                    line.move(to: CGPoint(x: position * scale, y: 25))
                                    line.addLine(to: CGPoint(x: position * scale, y: size.height))
                                    context.stroke(line, with: .color(.teal.opacity(state.metronome.isPlaying ? 1 : 0.35)), lineWidth: 2)
                                }
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }.frame(width: width, height: height)
                    }.frame(height: height)
                }
            }
        }
    }
    private func drawGrid(context: inout GraphicsContext, size: CGSize, signature: TimeSignature, subdivision: Subdivision, ticks: Int64, scale: Double) {
        let step = min(signature.beatTicks, subdivision.ticks)
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.rulerHeight)), with: .color(.primary.opacity(0.035)))
        for tick in stride(from: Int64(0), through: ticks, by: Int(step)) {
            let isBar = tick % signature.barTicks == 0
            let isBeat = tick % signature.beatTicks == 0
            let x = Double(tick) * scale
            var path = Path()
            path.move(to: CGPoint(x: x, y: isBar ? 0 : 26))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.primary.opacity(isBar ? 0.28 : isBeat ? 0.15 : 0.065)), lineWidth: isBar ? 1.5 : 1)
            if isBar && tick < ticks {
                context.draw(Text("ТАКТ \(tick / signature.barTicks + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: x + 8, y: 12), anchor: .leading)
            }
            if tick < ticks, isBeat || Double(step) * scale >= 20 {
                let label = RhythmEngine.gridLabel(ticks: tick, signature: signature, subdivision: subdivision)
                context.draw(Text(label).font(.system(size: 11, weight: isBeat ? .semibold : .regular)).foregroundStyle(.secondary), at: CGPoint(x: x + 5, y: 42), anchor: .leading)
            }
        }
    }
}

struct LyricsTrack: View {
    let line: LyricsLine
    let number: Int
    let signature: TimeSignature
    let scale: Double
    var body: some View {
        Canvas { context, size in
            if number.isMultiple(of: 2) {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.025)))
            }
            let color = densityColor(RhythmEngine.density(for: line, signature: signature))
            for (index, syllable) in line.syllables.enumerated() {
                let wordEnd = index == line.syllables.count - 1 || line.syllables[index + 1].wordIndex != syllable.wordIndex
                let x = Double(line.startPosition.ticks + syllable.position.ticks) * scale
                let allocatedWidth = Double(syllable.duration.ticks) * scale
                let gap = min(allocatedWidth * 0.2, wordEnd ? 7 : 1.5)
                let rect = CGRect(x: x, y: 28, width: max(0.5, allocatedWidth - gap), height: 34)
                SyllableBlock.draw(syllable, rect: rect, color: color, context: &context)
            }
            let end = Double(line.endTicks) * scale
            var boundary = Path()
            boundary.move(to: CGPoint(x: end, y: 20))
            boundary.addLine(to: CGPoint(x: end, y: 75))
            context.stroke(boundary, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var bottom = Path()
            bottom.move(to: CGPoint(x: 0, y: size.height))
            bottom.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(bottom, with: .color(.primary.opacity(0.08)), lineWidth: 1)
        }
        .accessibilityElement()
        .accessibilityLabel("Строка \(number): \(line.originalText)")
        .accessibilityValue(String(format: "%.2f слога на долю", RhythmEngine.density(for: line, signature: signature)))
    }
}

enum SyllableBlock {
    static func draw(_ syllable: Syllable, rect: CGRect, color: Color, context: inout GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 3))
        context.fill(shape, with: .color(color.opacity(syllable.wordIndex.isMultiple(of: 2) ? 0.22 : 0.32)))
        context.stroke(shape, with: .color(color.opacity(0.65)), lineWidth: 0.75)
        guard rect.width > 14 else { return }
        var clipped = context
        clipped.clip(to: shape)
        clipped.draw(Text(syllable.text).font(.system(size: 12, weight: .medium)), at: CGPoint(x: rect.midX, y: rect.midY))
        if rect.width > 100 {
            var stretch = Path()
            stretch.move(to: CGPoint(x: rect.minX + 8, y: rect.maxY - 5))
            stretch.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 5))
            clipped.stroke(stretch, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
}
