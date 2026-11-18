import EditCore
import SwiftUI

/// A physical-feeling key: travels down when pressed, glows Signal when active.
struct InstrumentButtonStyle: ButtonStyle {
    enum Kind { case key, dark, prominent }

    var kind: Kind = .dark
    var isActive = false
    /// Slimmer keys (the mode strip) trade height for room; they stay full width to tap.
    var height: CGFloat = Theme.minTouch
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.caption)
            .textCase(.uppercase)
            .foregroundStyle(foreground)
            .shadow(color: isActive && kind == .dark ? Theme.signal.opacity(0.7) : .clear, radius: 4)
            .frame(minWidth: height < Theme.minTouch ? 34 : Theme.minTouch, minHeight: height)
            .padding(.horizontal, height < Theme.minTouch ? 6 : 10)
            .offset(y: pressed ? 1.5 : 0)
            .background(KeyCap(kind: kind, isLit: isActive, isPressed: pressed, compact: height < Theme.minTouch))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
            .onChange(of: pressed) { _, isDown in
                if isDown { Haptics.press() }
            }
    }

    private var foreground: Color {
        switch kind {
        case .key, .prominent: return Theme.obsidian
        case .dark: return isActive ? Theme.signal : Theme.ivory
        }
    }
}

/// A machined key: a cap seated in a dark well, bevelled light on top and shadowed below, that
/// sinks when pressed. Dark caps are graphite, `.key` caps brushed aluminum, `.prominent` Signal.
/// A lit cap shows an LED and a Signal ring.
struct KeyCap: View {
    var kind: InstrumentButtonStyle.Kind = .dark
    var isLit = false
    var isPressed = false
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : Theme.cornerRadius, style: .continuous)
        ZStack {
            // The well the key sits in, with a faint lit lip below it.
            shape.fill(Color.black.opacity(0.75)).padding(-2).offset(y: 1.5)
            shape.stroke(Color.white.opacity(0.07), lineWidth: 1).padding(-2.5).offset(y: 2.5)
            shape.fill(fill)
                .overlay {
                    if kind == .key { BrushedMetal(strength: 0.6).clipShape(shape).blendMode(.multiply) }
                }
                .overlay(Grain(opacity: kind == .dark ? 0.45 : 0.3).clipShape(shape))
                // A domed top: light pools in the upper middle of the cap.
                .overlay(
                    shape.fill(
                        EllipticalGradient(
                            colors: [Color.white.opacity(isPressed ? 0.02 : (kind == .dark ? 0.13 : 0.35)), .clear],
                            center: UnitPoint(x: 0.5, y: 0.05), startRadiusFraction: 0, endRadiusFraction: 0.75))
                )
                .overlay(
                    // Bevel: catches light along the top, falls into shadow along the bottom.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isPressed ? 0.05 : (kind == .dark ? 0.24 : 0.75)),
                                Color.white.opacity(0.02), Color.black.opacity(0.55),
                            ], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.3)
                )
                .overlay(
                    shape.strokeBorder(isLit ? Theme.signal : .clear, lineWidth: 1.4)
                        .shadow(color: isLit ? Theme.signal.opacity(0.75) : .clear, radius: 7)
                )
                .overlay(alignment: compact ? .leading : .topTrailing) {
                    if isLit {
                        LED(isOn: true).padding(compact ? 8 : 5)
                    }
                }
                .shadow(
                    color: .black.opacity(isPressed ? 0.3 : 0.85), radius: isPressed ? 0.5 : 1, y: isPressed ? 0.5 : 1.5
                )
                .shadow(color: .black.opacity(isPressed ? 0 : 0.45), radius: 6, y: 4)
                .offset(y: isPressed ? 1.5 : 0)
        }
        .accessibilityHidden(true)
    }

    private var fill: LinearGradient {
        switch kind {
        case .key:
            LinearGradient(
                colors: isPressed
                    ? [Theme.aluminum, Theme.ivory] : [Theme.ivory, Theme.aluminum, Color(hex: 0x9C9E91)],
                startPoint: .top, endPoint: .bottom)
        case .prominent:
            LinearGradient(
                colors: [Color(hex: 0xE1EA80), Theme.signal, Color(hex: 0x9EA83E)], startPoint: .top, endPoint: .bottom)
        case .dark:
            LinearGradient(
                colors: isPressed
                    ? [Theme.obsidian, Color(hex: 0x262C25)]
                    : [Color(hex: 0x434C40), Theme.instrument, Color(hex: 0x1B201A)],
                startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Fine horizontal grain, like brushed metal. Deterministic, so it never shimmers on redraw.
struct BrushedMetal: View {
    var strength: Double = 1

    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            var i: UInt32 = 0
            while y < size.height {
                i &+= 1
                // A cheap hash gives each line its own steady brightness.
                let h = (i &* 2_654_435_761) >> 24
                let shade = Double(h) / 255
                let color = shade > 0.5 ? Color.white : Color.black
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)),
                    with: .color(color.opacity(abs(shade - 0.5) * 0.12 * strength)))
                y += 1
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Sets the view into the panel like a screen: a dark well with an inner shadow along its
    /// top and a faint lit lip along the bottom.
    func recessed(cornerRadius: CGFloat = Theme.cornerRadius, padding: CGFloat = 0) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.padding(padding)
            .background(
                shape.fill(Theme.obsidian.shadow(.inner(color: .black.opacity(0.9), radius: 4, y: 2)))
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.black.opacity(0.6), .clear, Color.white.opacity(0.09)], startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            )
    }
}

extension ButtonStyle where Self == InstrumentButtonStyle {
    static func instrument(
        _ kind: InstrumentButtonStyle.Kind = .dark, active: Bool = false, height: CGFloat = Theme.minTouch
    ) -> InstrumentButtonStyle {
        InstrumentButtonStyle(kind: kind, isActive: active, height: height)
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

/// A jog/shuttle wheel: a fat knurled aluminum drum seen edge-on in a recessed slot, turned by
/// dragging sideways (right is forward). It follows the finger one to one. Near where the finger
/// lands it jogs, a frame per detent. With `onShuttle`, pushing further out plays: the speed steps
/// up quickly the further out it goes (¼×, ½×, 1×, 2×, 4×, backwards to the left), lit on the
/// LED meter above the drum, and letting go stops. Without it (moving a curve point), the whole
/// travel jogs, gathering frames faster on quick drags. The wheel never edits by itself.
struct JogDial: View {
    /// What a turn moves, shown above the drum (e.g. "JOG", "POINT").
    var title: String
    var onStep: (Int) -> Void
    /// Pushed out of the middle: the speed to play at; nil back in the middle or when let go.
    var onShuttle: ((Float?) -> Void)?
    var onEnd: () -> Void = {}

    /// Points of travel per frame while jogging.
    private static let pointsPerFrame: CGFloat = 6
    /// How far either side of the touch-down point still jogs.
    private static let jogZone: CGFloat = 22
    /// Travel beyond the jog zone to reach the fastest shuttle speed.
    private static let shuttleReach: CGFloat = 80
    /// Shuttle speeds, slowest first.
    static let shuttleRates: [Float] = [0.25, 0.5, 1, 2, 4]
    /// How fast the drum spins per unit of shuttle speed (points per second).
    private static let spinSpeed: CGFloat = 60
    /// Spacing of the knurled ridges round the drum.
    private static let ridgeSpacing: CGFloat = 11
    static let drumHeight: CGFloat = 58

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
        VStack(spacing: 5) {
            meter
            TimelineView(.animation(paused: level == 0)) { timeline in
                let spin = CGFloat(rate ?? 0) * Self.spinSpeed * CGFloat(timeline.date.timeIntervalSince(spinStart))
                drum(turn: turn + spin)
            }
            .frame(height: Self.drumHeight)
            .padding(4)
            .recessed(cornerRadius: 14, padding: 0)
            .overlay(alignment: .top) {
                // The fixed index: a Signal notch in the slot's top lip.
                Triangle().fill(Theme.signal)
                    .frame(width: 10, height: 6)
                    .shadow(color: Theme.signal.opacity(0.9), radius: 3)
                    .offset(y: -1)
            }
            .contentShape(Rectangle())
            .gesture(isEnabled ? turnGesture : nil)
            .accessibilityElement()
            .accessibilityLabel("Jog dial")
            .accessibilityValue(rate.map(Self.label) ?? title.capitalized)
            .accessibilityHint("Swipe up or down to move one frame.")
            .accessibilityAdjustableAction { direction in onStep(direction == .increment ? 1 : -1) }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    /// The title, an LED meter of the shuttle speed either side of centre, and the speed.
    private var meter: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.mono(9, weight: .bold))
                .foregroundStyle(Theme.secondaryLabel)
                .frame(width: 40, alignment: .leading)
            HStack(spacing: 3) {
                ForEach((1...Self.shuttleRates.count).reversed(), id: \.self) { segment(lit: level <= -$0) }
                Circle().fill(level == 0 && last != nil ? Theme.signal : Theme.ivory.opacity(0.35))
                    .frame(width: 5, height: 5)
                ForEach(1...Self.shuttleRates.count, id: \.self) { segment(lit: level >= $0) }
            }
            .frame(maxWidth: .infinity)
            Text(rate.map(Self.label) ?? "")
                .font(Theme.mono(9, weight: .bold))
                .foregroundStyle(Theme.signal)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }

    private func segment(lit: Bool) -> some View {
        Capsule()
            .fill(lit ? Theme.signal : Color.black.opacity(0.55))
            .overlay(Capsule().strokeBorder(Color.white.opacity(lit ? 0 : 0.08), lineWidth: 0.5))
            .frame(minWidth: 6, maxWidth: 14, minHeight: 4, maxHeight: 4)
            .shadow(color: lit ? Theme.signal.opacity(0.9) : .clear, radius: 3)
    }

    /// The drum: brushed aluminum shaded round a vertical axis, its knurled ridges sliding past
    /// with the turn and crowding together towards the ends.
    private func drum(turn: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x2A2D26), location: 0),
                        .init(color: Color(hex: 0x8E9185), location: 0.14),
                        .init(color: Theme.ivory, location: 0.4),
                        .init(color: Theme.aluminum, location: 0.6),
                        .init(color: Color(hex: 0x7C7F73), location: 0.86),
                        .init(color: Color(hex: 0x23261F), location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
            BrushedMetal(strength: 1.4).clipShape(shape).blendMode(.multiply)
            Canvas { context, size in
                let radius = size.width / 2
                let spacing = Self.ridgeSpacing
                let phase = turn.truncatingRemainder(dividingBy: spacing)
                let count = Int(radius * .pi / 2 / spacing) + 2
                for k in -count...count {
                    let angle = (CGFloat(k) * spacing + phase) / radius
                    guard abs(angle) < .pi / 2 * 0.97 else { continue }
                    let x = radius + radius * sin(angle)
                    let depth = cos(angle)
                    let groove = max(0.8, 4 * depth)
                    // A dark groove with a lit edge on the side facing the light.
                    context.fill(
                        Path(CGRect(x: x - groove / 2, y: 5, width: groove, height: size.height - 10)),
                        with: .color(Color.black.opacity(0.22 + 0.33 * Double(depth))))
                    context.fill(
                        Path(CGRect(x: x + groove / 2, y: 5, width: max(0.5, 1.6 * depth), height: size.height - 10)),
                        with: .color(Color.white.opacity(0.12 + 0.5 * Double(depth))))
                }
            }
            .clipShape(shape)
            Grain(opacity: 0.35).clipShape(shape)
            // A hot spot where the light catches the drum's curve.
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.28), .init(color: .white.opacity(0.45), location: 0.38),
                        .init(color: .clear, location: 0.5),
                    ], startPoint: .leading, endPoint: .trailing)
            )
            .blendMode(.screen)
            // Light along the top lip, shade along the bottom: the drum's rim.
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.18),
                        .init(color: .clear, location: 0.75),
                        .init(color: Color.black.opacity(0.45), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
            if level != 0 {
                shape.strokeBorder(Theme.signal.opacity(0.8), lineWidth: 1.5)
                    .shadow(color: Theme.signal.opacity(0.8), radius: 5)
            }
            Rectangle().fill(Theme.signal.opacity(0.85))
                .frame(width: 1.5)
                .padding(.vertical, 2)
                .blendMode(.plusLighter)
        }
        .shadow(color: .black.opacity(0.7), radius: 2, y: 2)
        .accessibilityHidden(true)
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
        let steps = Self.shuttleRates.count
        let step = min(steps, 1 + Int((distance - Self.jogZone) / Self.shuttleReach * CGFloat(steps)))
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

/// A small triangle pointing down, for index marks.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// Spun metal, as on a machined knob or round key: a conical sheen turning about the centre,
/// fine concentric rings, and grain.
struct SpunMetal: View {
    var tint: Color = Theme.aluminum
    var rings = true

    var body: some View {
        ZStack {
            Circle().fill(tint)
            Circle().fill(
                AngularGradient(
                    colors: [
                        .white.opacity(0.55), .black.opacity(0.25), .white.opacity(0.35), .black.opacity(0.3),
                        .white.opacity(0.55), .black.opacity(0.25), .white.opacity(0.35), .black.opacity(0.3),
                        .white.opacity(0.55),
                    ], center: .center)
            )
            .blendMode(.overlay)
            if rings {
                Canvas { context, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    var r: CGFloat = 2
                    var i = 0
                    while r < size.width / 2 {
                        i += 1
                        let shade = (i * 7919) % 5 == 0 ? Color.white : Color.black
                        context.stroke(
                            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                            with: .color(shade.opacity(0.06)), lineWidth: 0.6)
                        r += 1.2
                    }
                }
            }
            Grain(opacity: 0.35).clipShape(Circle())
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}

/// A round machined key, like a transport button on a deck: a spun-metal cap in a dark bezel
/// ring, domed, sinking when pressed. Lit keys glow Signal; `prominent` is a Signal cap.
struct RoundKeyStyle: ButtonStyle {
    var diameter: CGFloat = 48
    var isLit = false
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        RoundKeyFace(diameter: diameter, isLit: isLit, prominent: prominent, isPressed: pressed) {
            configuration.label
        }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        .onChange(of: pressed) { _, isDown in
            if isDown { Haptics.press() }
        }
    }
}

/// The look of a round key, for places a button style can't reach (a menu's label).
struct RoundKeyFace<Label: View>: View {
    var diameter: CGFloat = 48
    var isLit = false
    var prominent = false
    var isPressed = false
    @ViewBuilder var label: Label

    var body: some View {
        let pressed = isPressed
        let face = prominent ? Theme.signal : Theme.aluminum
        label
            .font(.system(size: diameter * 0.32, weight: .bold))
            .foregroundStyle(prominent ? Theme.obsidian : (isLit ? Theme.signal : Color(hex: 0x23281F)))
            .shadow(color: .white.opacity(prominent ? 0.25 : 0.45), radius: 0, y: 1)
            .offset(y: pressed ? 1.5 : 0)
            .frame(width: diameter, height: diameter)
            .background {
                ZStack {
                    // Bezel ring set into the panel.
                    Circle().fill(Color.black.opacity(0.8)).padding(-5).offset(y: 1)
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.black.opacity(0.7), Color.white.opacity(0.12)], startPoint: .top,
                                endPoint: .bottom), lineWidth: 1.5
                        )
                        .padding(-5)
                    if isLit || prominent {
                        Circle().strokeBorder(Theme.signal.opacity(isLit ? 0.9 : 0.4), lineWidth: 2)
                            .padding(-4)
                            .shadow(color: Theme.signal.opacity(0.8), radius: isLit ? 8 : 4)
                    }
                    SpunMetal(tint: pressed ? face.opacity(0.85) : face)
                        .overlay(
                            Circle().fill(
                                RadialGradient(
                                    colors: [.white.opacity(pressed ? 0.05 : 0.3), .clear],
                                    center: UnitPoint(x: 0.5, y: 0.15), startRadius: 0, endRadius: diameter * 0.6))
                        )
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.8), .black.opacity(0.5)], startPoint: .top,
                                    endPoint: .bottom),
                                lineWidth: 1)
                        )
                        .shadow(
                            color: .black.opacity(pressed ? 0.3 : 0.8), radius: pressed ? 0.5 : 2, y: pressed ? 0.5 : 2
                        )
                        .offset(y: pressed ? 1.5 : 0)
                }
            }
            .frame(width: diameter + 10, height: diameter + 10)
            .contentShape(Circle())
    }
}

extension ButtonStyle where Self == RoundKeyStyle {
    static func round(_ diameter: CGFloat = 48, lit: Bool = false, prominent: Bool = false) -> RoundKeyStyle {
        RoundKeyStyle(diameter: diameter, isLit: lit, prominent: prominent)
    }
}

/// A slotted screw head, for panel corners.
struct Screw: View {
    var angle: Double = 30

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.6)).padding(-1).offset(y: 0.5)
            SpunMetal(tint: Theme.aluminum.opacity(0.9), rings: false)
            Capsule().fill(Color.black.opacity(0.65)).frame(width: 7, height: 1.6).rotationEffect(.degrees(angle))
        }
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)
    }
}
