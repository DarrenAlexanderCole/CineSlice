import SwiftUI

/// A rotary knob for one setting (`value` is its position, 0…1): a spun-metal cap with a Signal
/// pointer, in a ring lit from its rest point (`detent`, or the bottom) to the value. It turns by
/// forgiving linear dragging, up or right for more, never circular tracing, moving from where it
/// was so grabbing it never makes it jump; a double tap puts it back at `reset`. `onChange` fires
/// live while dragging, `onCommit` once on release (one undo step), as `Fader` does.
struct Knob: View {
    let title: String
    let value: Double
    /// A position with a haptic click, the ring lighting either side of it (e.g. 0 dB).
    var detent: Double?
    var reset: Double
    /// The setting at a position, as shown under the knob.
    var text: (Double) -> String
    var onChange: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var draft: Double?
    @State private var base: Double = 0

    /// Points of drag for the whole travel.
    private static let travel: CGFloat = 180
    /// The ring's sweep, from bottom-left round to bottom-right.
    private static let sweep = 270.0
    private let size: CGFloat = 40

    var body: some View {
        let shown = draft ?? value
        VStack(spacing: 4) {
            Text(title)
                .font(Theme.mono(9, weight: .bold))
                .foregroundStyle(Theme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ZStack {
                ring(shown)
                cap(shown)
            }
            .frame(width: size + 12, height: size + 12)
            .contentShape(Rectangle())
            .gesture(turn)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard isEnabled, value != reset else { return }
                    Haptics.detent()
                    onCommit(reset)
                })
            Text(text(shown))
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(draft == nil ? Theme.label : Theme.signal)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text(value))
        .accessibilityHint("Swipe up or down to adjust. Double-tap and hold, then drag, to turn it.")
        .accessibilityAdjustableAction { direction in
            onCommit(min(max(value + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }

    private func angle(_ position: Double) -> Angle { .degrees(-Self.sweep / 2 + position * Self.sweep) }

    /// The slot round the cap, lit from the rest point to the value.
    private func ring(_ position: Double) -> some View {
        let start = 0.5 - Self.sweep / 720
        let from = detent ?? 0
        let lit = (min(from, position), max(from, position))
        return ZStack {
            Circle()
                .trim(from: start, to: 1 - start)
                .stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Circle()
                .trim(from: start + lit.0 * (1 - 2 * start), to: start + lit.1 * (1 - 2 * start))
                .stroke(Theme.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: Theme.signal.opacity(0.8), radius: 2.5)
                .opacity(isEnabled && lit.1 > lit.0 ? 1 : 0)
        }
        // trim runs clockwise from 3 o'clock; turn so the gap sits at the bottom.
        .rotationEffect(.degrees(90))
        .padding(3)
    }

    private func cap(_ position: Double) -> some View {
        ZStack {
            SpunMetal(rings: true)
            Capsule()
                .fill(Theme.signal)
                .frame(width: 2.5, height: size * 0.32)
                .offset(y: -size * 0.27)
                .shadow(color: Theme.signal.opacity(0.9), radius: 2)
                .rotationEffect(angle(position))
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.7), Color.black.opacity(0.5)], startPoint: .top,
                    endPoint: .bottom), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
    }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard isEnabled else { return }
                if draft == nil {
                    base = value
                    draft = value
                    Haptics.press()
                }
                let previous = draft ?? value
                let moved = (g.translation.width - g.translation.height) / Self.travel
                let next = min(max(base + Double(moved), 0), 1)
                let marks = [0, 1] + (detent.map { [$0] } ?? [])
                if marks.contains(where: { (previous - $0) * (next - $0) < 0 || (next == $0 && previous != $0) }) {
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
