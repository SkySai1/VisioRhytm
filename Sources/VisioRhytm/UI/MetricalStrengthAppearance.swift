import SwiftUI
import VisioRhytmCore

// All display choices belong to UI; the rhythm model contains only semantics.
extension MetricalStrength {
    var label: String {
        switch self {
        case .primary: "Сильная"
        case .secondary: "Вторично сильная"
        case .weak: "Слабая"
        case .subdivision: "Между долями"
        }
    }
    var symbol: String {
        switch self {
        case .primary: "chevron.up.2"
        case .secondary: "chevron.up"
        case .weak: "minus"
        case .subdivision: "ellipsis"
        }
    }
    var columnColor: Color {
        switch self { case .primary: .orange; case .secondary: .blue; case .weak: .gray; case .subdivision: .gray }
    }
    var columnOpacity: Double {
        switch self { case .primary: 0.24; case .secondary: 0.16; case .weak: 0.075; case .subdivision: 0.03 }
    }
    var lineOpacity: Double {
        switch self { case .primary: 0.4; case .secondary: 0.28; case .weak: 0.16; case .subdivision: 0.07 }
    }
    var lineWidth: Double {
        switch self { case .primary: 1.75; case .secondary: 1.3; case .weak: 1; case .subdivision: 0.5 }
    }
    var labelWeight: Font.Weight {
        switch self { case .primary: .bold; case .secondary: .semibold; case .weak: .medium; case .subdivision: .regular }
    }
}

struct MetricalStrengthLegend: View {
    let signature: TimeSignature
    private var supportDescription: String {
        let pattern = RhythmEngine.beatStrengths(signature: signature)
        let primary = pattern.indices.filter { pattern[$0] == .primary }.map { String($0 + 1) }.joined(separator: ", ")
        let secondary = pattern.indices.filter { pattern[$0] == .secondary }.map { String($0 + 1) }.joined(separator: ", ")
        return "\(signature): сильная — \(primary)" + (secondary.isEmpty ? "" : "; вторично сильные — \(secondary)")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                ForEach(MetricalStrength.allCases, id: \.self) { strength in
                    HStack(spacing: 5) {
                        Image(systemName: strength.symbol)
                            .font(.system(size: 8, weight: strength.labelWeight))
                            .frame(width: 20, height: 16)
                            .background(strength.columnColor.opacity(strength.columnOpacity), in: RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(strength.lineOpacity)))
                        Text(strength.label)
                    }
                }
            }
            Text(supportDescription).foregroundStyle(.secondary)
            Text("Цвет и насыщенность всей колонки показывают силу позиции. Любой слог можно поставить в любую позицию.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
