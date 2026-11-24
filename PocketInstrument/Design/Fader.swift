import SwiftUI

/// Horizontal level fader (0…1). Dragging moves the level relative to where it
/// was, so grabbing anywhere on the track never makes it jump. `onChange`
/// fires on touch and live while dragging; `onCommit` fires once on release (one undo step)
/// unless `onRelease` returns true to say the release was handled (e.g. a recorded pass).
/// `display` labels a position (a percent by default); `detents` are where it ticks.
struct Fader: View {
    let title: String
    let value: Float
    var detents: [Float] = [0, 0.5, 1]
    var display: (Float) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var onChange: (Float) -> Void = { _ in }
    var onRelease: (Float) -> Bool = { _ in false }
    var onCommit: (Float) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var draft: Float?
    @State private var base: Float = 0

    private let thumbWidth: CGFloat = 14

    var body: some View {
        let shown = draft ?? value
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
                Spacer()
                Text(display(shown))
                    .font(Theme.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(draft == nil ? Theme.label : Theme.signal)
            }
            GeometryReader { geo in
                let travel = max(1, geo.size.width - thumbWidth)
                let x = CGFloat(shown) * travel
                ZStack(alignment: .leading) {
                    // A slot cut into the panel.
                    Capsule().fill(Color.black.shadow(.inner(color: .black, radius: 2, y: 1)))
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.clear, Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                        )
                        .frame(height: 8)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.olive, Theme.signal], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: x + thumbWidth / 2, height: 6)
                        .opacity(isEnabled ? 1 : 0.3)
                    // A machined cap with grip ridges and a Signal index line.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.ivory, Theme.aluminum, Color(hex: 0x8F9186)], startPoint: .top,
                                endPoint: .bottom)
                        )
                        .overlay(
                            VStack(spacing: 2.5) {
                                ForEach(0..<6, id: \.self) { i in
                                    Rectangle()
                                        .fill(i == 2 || i == 3 ? Theme.obsidian : Color.black.opacity(0.25))
                                        .frame(height: 1)
                                }
                            }
                            .padding(.horizontal, 3)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.8), Color.black.opacity(0.4)], startPoint: .top,
                                        endPoint: .bottom), lineWidth: 0.8)
                        )
                        .frame(width: thumbWidth, height: 28)
                        .shadow(color: .black.opacity(0.6), radius: 2.5, y: 2)
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
        .accessibilityValue(display(value))
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
                if detents.contains(where: { (previous - $0) * (next - $0) < 0 || (next == $0 && previous != $0) }) {
                    Haptics.detent()
                }
                draft = next
                onChange(next)
            }
            .onEnded { _ in
                guard let final = draft else { return }
                draft = nil
                if onRelease(final) { return }
                if final != value { onCommit(final) }
            }
    }
}
