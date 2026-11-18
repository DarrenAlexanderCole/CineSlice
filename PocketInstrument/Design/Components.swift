import EditCore
import SwiftUI

/// A physical-feeling key: travels down when pressed, glows Signal when active.
struct InstrumentButtonStyle: ButtonStyle {
    enum Kind { case key, dark, prominent }

    var kind: Kind = .dark
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.caption)
            .textCase(.uppercase)
            .foregroundStyle(foreground)
            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(0.55), radius: pressed ? 1 : 4, y: pressed ? 1 : 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isActive ? Theme.signal : Theme.hairline, lineWidth: isActive ? 1.5 : 1)
                    .shadow(color: isActive ? Theme.signal.opacity(0.6) : .clear, radius: 6)
            )
            .offset(y: pressed ? 2 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
            .onChange(of: pressed) { _, isDown in
                if isDown { Haptics.press() }
            }
    }

    private var fill: LinearGradient {
        switch kind {
        case .key:
            return LinearGradient(colors: [Theme.ivory, Theme.aluminum], startPoint: .top, endPoint: .bottom)
        case .prominent:
            return LinearGradient(
                colors: [Theme.signal, Theme.signal.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        case .dark:
            return LinearGradient(
                colors: [Theme.instrument.opacity(1.0), Theme.obsidian], startPoint: .top, endPoint: .bottom)
        }
    }

    private var foreground: Color {
        switch kind {
        case .key, .prominent: return Theme.obsidian
        case .dark: return isActive ? Theme.signal : Theme.ivory
        }
    }
}

extension ButtonStyle where Self == InstrumentButtonStyle {
    static func instrument(_ kind: InstrumentButtonStyle.Kind = .dark, active: Bool = false) -> InstrumentButtonStyle {
        InstrumentButtonStyle(kind: kind, isActive: active)
    }
}

/// Monospaced timecode readout.
struct TimecodeText: View {
    let time: MediaTime
    var frameRate: Double = 30
    var size: CGFloat = 14
    var color: Color = Theme.label

    var body: some View {
        Text(time.timecode(frameRate: frameRate))
            .font(Theme.mono(size))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel(String(format: "%.2f seconds", time.seconds))
    }
}

/// Smoked-glass chip for information overlaid on footage.
struct GlassChip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Theme.obsidian.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .environment(\.colorScheme, .dark)
    }
}

/// Small LED dot that lights in Signal.
struct LED: View {
    var isOn: Bool
    var body: some View {
        Circle()
            .fill(isOn ? Theme.signal : Theme.instrument)
            .frame(width: 6, height: 6)
            .shadow(color: isOn ? Theme.signal.opacity(0.9) : .clear, radius: 4)
            .accessibilityHidden(true)
    }
}

/// A jog/shuttle wheel seen edge-on. Near where the finger lands it jogs: a frame per detent,
/// right is forward. With `onShuttle`, pushing further out plays: the speed steps up the
/// further out it goes (¼×, ½×, 1×, 2×, 4× at the edge, backwards to the left) and letting go
/// stops. Without it (moving a curve point), the whole travel jogs, gathering frames faster on
/// quick drags. The wheel never edits anything itself.
struct JogDial: View {
    /// What a turn moves, shown on the wheel (e.g. "JOG", "POINT").
    var title: String
    var onStep: (Int) -> Void
    /// Pushed out of the middle: the speed to play at; nil back in the middle or when let go.
    var onShuttle: ((Float?) -> Void)?
    var onEnd: () -> Void = {}

    /// Points of travel per frame while jogging.
    private static let pointsPerFrame: CGFloat = 9
    /// How far either side of the touch-down point still jogs.
    private static let jogZone: CGFloat = 30
    /// Shuttle speeds, slowest first; the last is reached near the dial's edge.
    static let shuttleRates: [Float] = [0.25, 0.5, 1, 2, 4]
    /// How fast the ticks spin per unit of shuttle speed (points per second).
    private static let spinSpeed: CGFloat = 45

    @State private var width: CGFloat = 300
    @State private var turn: CGFloat = 0
    @State private var last: (translation: CGFloat, time: Date)?
    @State private var pending: CGFloat = 0
    @State private var lastClick = Date.distantPast
    /// Signed shuttle step: 0 jogging, ±1…±5 playing at `shuttleRates[|level| - 1]`.
    @State private var level = 0
    @State private var spinStart = Date()
    @Environment(\.isEnabled) private var isEnabled

    private var rate: Float? {
        level == 0 ? nil : Self.shuttleRates[abs(level) - 1] * (level > 0 ? 1 : -1)
    }

    var body: some View {
        TimelineView(.animation(paused: level == 0)) { timeline in
            let spin = CGFloat(rate ?? 0) * Self.spinSpeed * CGFloat(timeline.date.timeIntervalSince(spinStart))
            wheel(turn: turn + spin)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.obsidian, Theme.instrument, Theme.obsidian], startPoint: .leading,
                        endPoint: .trailing))
        )
        .overlay(alignment: .leading) { tag(title, color: Theme.secondaryLabel) }
        .overlay(alignment: .trailing) {
            if let rate { tag(Self.label(rate), color: Theme.signal) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(last == nil ? Theme.hairline : Theme.signal.opacity(0.7))
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .frame(height: Theme.minTouch)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .gesture(isEnabled ? turnGesture : nil)
        .accessibilityElement()
        .accessibilityLabel("Jog dial")
        .accessibilityValue(rate.map(Self.label) ?? title.capitalized)
        .accessibilityHint("Swipe up or down to move one frame.")
        .accessibilityAdjustableAction { direction in onStep(direction == .increment ? 1 : -1) }
    }

    private func wheel(turn: CGFloat) -> some View {
        Canvas { context, size in
            let radius = size.width / 2
            let spacing = Self.pointsPerFrame
            let phase = turn.truncatingRemainder(dividingBy: spacing)
            let count = Int(radius * .pi / 2 / spacing) + 2
            for k in -count...count {
                let angle = (CGFloat(k) * spacing + phase) / radius
                guard abs(angle) < .pi / 2 else { continue }
                let x = radius + radius * sin(angle)
                let depth = cos(angle)
                let height = size.height * (0.32 + 0.3 * depth)
                let rect = CGRect(
                    x: x - 1, y: (size.height - height) / 2, width: max(1, 2.2 * depth), height: height)
                context.fill(Path(rect), with: .color(Theme.aluminum.opacity(0.15 + 0.6 * Double(depth))))
            }
            let index = CGRect(x: radius - 1, y: 4, width: 2, height: size.height - 8)
            context.fill(Path(roundedRect: index, cornerRadius: 1), with: .color(Theme.signal))
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.mono(9))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.obsidian))
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
    }

    /// "▶ 2×", "◀ ½×" and so on.
    static func label(_ rate: Float) -> String {
        let speed: String =
            switch abs(rate) {
            case 0.25: "¼×"
            case 0.5: "½×"
            default: String(format: "%.0f×", abs(rate))
            }
        return (rate > 0 ? "▶ " : "◀ ") + speed
    }

    /// The shuttle step for a drag `offset` points from where the finger landed.
    private func shuttleLevel(_ offset: CGFloat) -> Int {
        let distance = abs(offset)
        guard distance > Self.jogZone else { return 0 }
        // From the edge of the jog zone to near the dial's edge (for a touch in the middle).
        let reach = max(width * 0.45 - Self.jogZone, 40)
        let steps = Self.shuttleRates.count
        let step = min(steps, 1 + Int((distance - Self.jogZone) / reach * CGFloat(steps)))
        return offset > 0 ? step : -step
    }

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let now = Date()
                let previous = last ?? (0, now)
                let delta = g.translation.width - previous.translation
                let seconds = max(now.timeIntervalSince(previous.time), 1.0 / 240)
                last = (g.translation.width, now)
                if let onShuttle {
                    let next = shuttleLevel(g.translation.width)
                    if next != level {
                        // Keep the spin so far, then spin at the new speed.
                        turn += CGFloat(rate ?? 0) * Self.spinSpeed * CGFloat(now.timeIntervalSince(spinStart))
                        spinStart = now
                        level = next
                        pending = 0
                        onShuttle(rate)
                        Haptics.press()
                    }
                    if level != 0 { return }
                }
                turn += delta
                // Point moves (no shuttle) gather up to 12 frames per detent on fast drags.
                let speed = abs(delta) / CGFloat(seconds)
                let gain = onShuttle == nil ? 1 + min(max((speed - 250) / 220, 0), 11) : 1
                pending += delta * gain / Self.pointsPerFrame
                let frames = Int(pending)
                guard frames != 0 else { return }
                pending -= CGFloat(frames)
                onStep(frames)
                if now.timeIntervalSince(lastClick) > 0.025 {
                    Haptics.detent()
                    lastClick = now
                }
            }
            .onEnded { _ in
                if level != 0 {
                    turn += CGFloat(rate ?? 0) * Self.spinSpeed * CGFloat(Date().timeIntervalSince(spinStart))
                    level = 0
                    onShuttle?(nil)
                }
                last = nil
                pending = 0
                onEnd()
            }
    }
}
