import SwiftUI

/// Horizontal level fader (0…1). Dragging moves the level relative to where it
/// was, so grabbing anywhere on the track never makes it jump. `onChange`
/// fires live while dragging; `onCommit` fires once on release (one undo step).
struct Fader: View {
    let title: String
    let value: Float
    var onChange: (Float) -> Void = { _ in }
    var onCommit: (Float) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var draft: Float?
    @State private var base: Float = 0

    private static let detents: [Float] = [0, 0.5, 1]
    private let thumbWidth: CGFloat = 14

    var body: some View {
        let shown = draft ?? value
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
                Spacer()
                Text("\(Int((shown * 100).rounded()))%")
                    .font(Theme.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(draft == nil ? Theme.label : Theme.signal)
            }
            GeometryReader { geo in
                let travel = max(1, geo.size.width - thumbWidth)
                let x = CGFloat(shown) * travel
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.obsidian)
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .frame(height: 6)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.olive, Theme.signal], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: x + thumbWidth / 2, height: 6)
                        .opacity(isEnabled ? 1 : 0.3)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Theme.ivory, Theme.aluminum], startPoint: .top, endPoint: .bottom)
                        )
                        .overlay(Rectangle().fill(Theme.obsidian).frame(width: 1.5, height: 14))
                        .frame(width: thumbWidth, height: 26)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .offset(x: x)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(travel: travel))
            }
            .frame(height: 28)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            onCommit(min(max(value + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard isEnabled else { return }
                if draft == nil {
                    base = value
                    draft = value
                    Haptics.press()
                }
                let previous = draft ?? value
                let next = min(max(base + Float(g.translation.width / travel), 0), 1)
                if Self.detents.contains(where: { (previous - $0) * (next - $0) < 0 || (next == $0 && previous != $0) })
                {
                    Haptics.detent()
                }
                draft = next
                onChange(next)
            }
            .onEnded { _ in
                guard let final = draft else { return }
                draft = nil
                if final != value { onCommit(final) }
            }
    }
}
