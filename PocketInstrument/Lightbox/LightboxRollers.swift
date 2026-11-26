import EditCore
import SwiftUI

/// A knurled thumb roller standing on end at the side of the light box, turned by dragging up
/// and down. It follows the finger one to one and reports each movement through `onTurn`, which
/// answers how much of it was used: at a limit the roller stops turning and clicks once. Flicked,
/// it coasts and slows to a stop (not with Reduce Motion). A lit slot beside it shows where in its
/// travel it is.
struct ThumbRoller: View {
    var label: String
    var value: String
    /// 0…1 along its travel, for the lit slot; nil hides the slot (nothing to travel through).
    var position: Double?
    /// Which side of the roller the slot sits on.
    var slotOnLeading: Bool
    /// Points moved, down positive. Returns the points actually used.
    var onTurn: (Double) -> Double
    var coasts = true

    @State private var turn: CGFloat = 0
    @State private var lastY: CGFloat?
    @State private var lastTime = Date()
    @State private var velocity: CGFloat = 0
    @State private var coast: Task<Void, Never>?
    @State private var atLimit = false
    @State private var lastClick = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ridgeSpacing: CGFloat = 7

    var body: some View {
        HStack(spacing: 4) {
            if slotOnLeading { slot }
            RollerWell(isLit: lastY != nil) {
                Canvas { context, size in
                    drawDrum(context: context, size: size, turn: turn)
                }
            }
            .frame(width: 34)
            .contentShape(Rectangle())
            .gesture(drag)
            if !slotOnLeading { slot }
        }
        .onDisappear { coast?.cancel() }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAdjustableAction { direction in
            apply(direction == .increment ? 24 : -24)
        }
    }

    /// The lit slot: a dark groove with a Signal bead at the current position.
    private var slot: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.5))
                if let position {
                    Capsule().fill(Theme.signal)
                        .frame(height: 10)
                        .shadow(color: Theme.signal.opacity(0.8), radius: 3)
                        .offset(y: (geo.size.height - 10) * min(max(position, 0), 1))
                }
            }
        }
        .frame(width: 3)
        .padding(.vertical, 10)
        .opacity(position == nil ? 0.35 : 1)
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                coast?.cancel()
                let now = Date()
                let dy = g.translation.height - (lastY ?? 0)
                let dt = max(now.timeIntervalSince(lastTime), 1.0 / 240)
                if lastY == nil { atLimit = false }
                lastY = g.translation.height
                lastTime = now
                velocity = velocity * 0.6 + dy / CGFloat(dt) * 0.4
                apply(Double(dy))
            }
            .onEnded { _ in
                lastY = nil
                guard coasts, !reduceMotion, abs(velocity) > 150 else {
                    velocity = 0
                    return
                }
                startCoast()
            }
    }

    /// Glides on after a flick, slowing steadily, until it stops or meets a limit.
    private func startCoast() {
        var v = velocity
        velocity = 0
        coast = Task { @MainActor in
            let tick = 1.0 / 60
            while !Task.isCancelled, abs(v) > 20 {
                try? await Task.sleep(for: .seconds(tick))
                let used = apply(Double(v) * tick)
                if used == 0 { return }
                v *= 0.92
            }
        }
    }

    @discardableResult
    private func apply(_ dy: Double) -> Double {
        guard dy != 0 else { return 0 }
        let used = onTurn(dy)
        if used == 0 {
            if !atLimit {
                atLimit = true
                Haptics.tap()
            }
            return 0
        }
        atLimit = false
        let before = Int((turn / Self.ridgeSpacing).rounded(.down))
        turn += CGFloat(used)
        let after = Int((turn / Self.ridgeSpacing).rounded(.down))
        let now = Date()
        if before != after, now.timeIntervalSince(lastClick) > 0.035 {
            Haptics.detent()
            lastClick = now
        }
        return used
    }

    /// Brass knurling round a horizontal axis: ridges slide by with the turn, crowding towards the
    /// top and bottom where the drum curves away, light pooled across its middle.
    private func drawDrum(context: GraphicsContext, size: CGSize, turn: CGFloat) {
        let radius = size.height / 2
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0x1E1C14), location: 0),
                    .init(color: Color(hex: 0x6E6040), location: 0.16),
                    .init(color: Color(hex: 0xE2D3A4), location: 0.45),
                    .init(color: Color(hex: 0xB59A62), location: 0.62),
                    .init(color: Color(hex: 0x5E5236), location: 0.86),
                    .init(color: Color(hex: 0x17150F), location: 1),
                ]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        let phase = turn.truncatingRemainder(dividingBy: Self.ridgeSpacing)
        let count = Int(radius * .pi / 2 / Self.ridgeSpacing) + 2
        for k in -count...count {
            let angle = (CGFloat(k) * Self.ridgeSpacing + phase) / radius
            guard abs(angle) < .pi / 2 * 0.96 else { continue }
            let y = radius + radius * sin(angle)
            let depth = cos(angle)
            let groove = max(0.6, 2.6 * depth)
            context.fill(
                Path(CGRect(x: 3, y: y - groove / 2, width: size.width - 6, height: groove)),
                with: .color(Color.black.opacity(0.25 + 0.35 * Double(depth))))
            context.fill(
                Path(CGRect(x: 3, y: y + groove / 2, width: size.width - 6, height: max(0.4, 1.1 * depth))),
                with: .color(Color.white.opacity(0.1 + 0.45 * Double(depth))))
        }
        // The drum's round sides: shade at both edges.
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.75), .init(color: .black.opacity(0.55), location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
    }
}

/// The pill-shaped well a thumb roller sits in, its rim lit Signal (brighter while held).
struct RollerWell<Drum: View>: View {
    var isLit: Bool
    @ViewBuilder var drum: Drum

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        drum
            .clipShape(shape)
            .padding(3)
            .background(shape.fill(Color.black.opacity(0.8)).padding(-1))
            .overlay(
                shape.strokeBorder(Theme.signal.opacity(isLit ? 0.95 : 0.55), lineWidth: 1.5)
                    .shadow(color: Theme.signal.opacity(isLit ? 0.9 : 0.45), radius: isLit ? 6 : 3)
                    .padding(-1)
            )
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
    }
}

/// The giant horizontal roller under the light box: a long knurled cylinder seen from the front,
/// with a scale and the playhead's index above it. It works like the upright jog dial (right is
/// forward): near where the finger lands it moves the playhead a frame per detent; pushed further
/// out and held it plays, faster the further out it goes (¼× to 4×, backwards to the left), the
/// drum spinning and the speed lit on the scale, and letting go stops. Every jog is a
/// frame-accurate seek, and the roller never leaves the project playing.
struct JogRoller: View {
    var model: WorkspaceModel

    @State private var turn: CGFloat = 0
    @State private var last: (x: CGFloat, time: Date)?
    @State private var pending: Double = 0
    @State private var lastClick = Date.distantPast
    @State private var atLimit = false
    /// Signed shuttle step: 0 jogging, ±1…±5 playing at `JogDial.shuttleRates[|level| - 1]`.
    @State private var level = 0
    @State private var spinStart = Date()
    private let mapping = JogRollerMapping()
    private static let ridgeSpacing: CGFloat = 5
    /// How fast the drum spins per unit of shuttle speed (points per second).
    private static let spinSpeed: CGFloat = 60

    private var rate: Float? {
        level == 0 ? nil : JogDial.shuttleRates[abs(level) - 1] * (level > 0 ? 1 : -1)
    }

    var body: some View {
        TimelineView(.animation(paused: level == 0)) { timeline in
            let turn = turn + spin(at: timeline.date)
            VStack(spacing: 2) {
                scale(turn: turn)
                Canvas { context, size in drawDrum(context: context, size: size, turn: turn) }
                    .clipShape(Capsule())
                    .padding(3)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), .clear, Color.black.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
                    .overlay {
                        if level != 0 {
                            Capsule().strokeBorder(Theme.signal.opacity(0.85), lineWidth: 1.5)
                                .shadow(color: Theme.signal.opacity(0.8), radius: 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        // The fixed index across the drum: where the playhead is.
                        Rectangle().fill(Color(hex: 0xFFB13B))
                            .frame(width: 2)
                            .shadow(color: Color(hex: 0xFFB13B).opacity(0.9), radius: 4)
                            .padding(.vertical, 2)
                            .allowsHitTesting(false)
                    }
            }
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .accessibilityElement()
        .accessibilityLabel("Playhead roller")
        .accessibilityValue(
            rate.map(JogDial.label) ?? model.currentTime.timecode(frameRate: model.jogFrameRate)
        )
        .accessibilityHint("Swipe up or down to move one frame. Drag further and hold to play.")
        .accessibilityAdjustableAction { direction in model.jog(by: direction == .increment ? 1 : -1) }
    }

    /// How far the drum has spun at the shuttle speed since it last changed.
    private func spin(at date: Date) -> CGFloat {
        CGFloat(rate ?? 0) * Self.spinSpeed * CGFloat(date.timeIntervalSince(spinStart))
    }

    /// Tick marks that slide with the drum, a tall one every fifth; the shuttle speed over the
    /// index while it plays.
    private func scale(turn: CGFloat) -> some View {
        Canvas { context, size in
            let spacing: CGFloat = 12
            let phase = turn.truncatingRemainder(dividingBy: spacing * 5)
            var x = phase - spacing * 5
            var i = 0
            while x < size.width + spacing {
                let tall = i % 5 == 0
                let h: CGFloat = tall ? size.height : size.height * 0.5
                context.fill(
                    Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                    with: .color(Theme.ivory.opacity(tall ? 0.7 : 0.35)))
                x += spacing
                i += 1
            }
            context.fill(
                Path(CGRect(x: size.width / 2 - 1, y: 0, width: 2, height: size.height)),
                with: .color(Color(hex: 0xFFB13B)))
        }
        .frame(height: 8)
        .padding(.horizontal, 24)
        .overlay {
            if let rate {
                Text(JogDial.label(rate))
                    .font(Theme.mono(9, weight: .heavy))
                    .foregroundStyle(Theme.obsidian)
                    .padding(.horizontal, 6)
                    .frame(height: 12)
                    .background(Capsule().fill(Theme.signal))
                    .shadow(color: Theme.signal.opacity(0.9), radius: 4)
                    .offset(y: -3)
            }
        }
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let now = Date()
                let previous = last ?? (0, now)
                let dx = g.translation.width - previous.x
                if last == nil { atLimit = false }
                last = (g.translation.width, now)
                let next = mapping.shuttleLevel(offset: Double(g.translation.width))
                if next != level {
                    // Keep the spin so far, then spin at the new speed.
                    turn += spin(at: now)
                    spinStart = now
                    level = next
                    pending = 0
                    model.shuttle(rate)
                    Haptics.press()
                }
                guard level == 0 else { return }
                pending += mapping.frames(dx: Double(dx))
                let frames = Int(pending)
                guard frames != 0 else { return }
                pending -= Double(frames)
                guard canMove(frames) else {
                    if !atLimit {
                        atLimit = true
                        Haptics.tap()
                    }
                    return
                }
                atLimit = false
                turn += dx
                model.jog(by: frames)
                if now.timeIntervalSince(lastClick) > 0.03 {
                    Haptics.detent()
                    lastClick = now
                }
            }
            .onEnded { _ in
                if level != 0 {
                    turn += spin(at: Date())
                    level = 0
                    model.shuttle(nil)
                }
                last = nil
                pending = 0
            }
    }

    /// No turning past either end of the project.
    private func canMove(_ frames: Int) -> Bool {
        let t = model.currentTime.seconds
        let end = model.engine.duration.seconds - 1 / model.jogFrameRate
        return frames > 0 ? t < end - 1e-4 : t > 1e-4
    }

    /// Aluminum shaded round a vertical axis, ridges crowding towards both ends.
    private func drawDrum(context: GraphicsContext, size: CGSize, turn: CGFloat) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0x24261F), location: 0),
                    .init(color: Color(hex: 0x7F8273), location: 0.08),
                    .init(color: Color(hex: 0xC9C3A6), location: 0.4),
                    .init(color: Color(hex: 0xA79E7C), location: 0.62),
                    .init(color: Color(hex: 0x6C6A5A), location: 0.92),
                    .init(color: Color(hex: 0x1E2019), location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        let radius = size.width / 2
        let phase = turn.truncatingRemainder(dividingBy: Self.ridgeSpacing)
        let count = Int(radius * .pi / 2 / Self.ridgeSpacing) + 2
        for k in -count...count {
            let angle = (CGFloat(k) * Self.ridgeSpacing + phase) / radius
            guard abs(angle) < .pi / 2 * 0.985 else { continue }
            let x = radius + radius * sin(angle)
            let depth = cos(angle)
            let groove = max(0.5, 2.2 * depth)
            context.fill(
                Path(CGRect(x: x - groove / 2, y: 0, width: groove, height: size.height)),
                with: .color(Color.black.opacity(0.2 + 0.3 * Double(depth))))
            context.fill(
                Path(CGRect(x: x + groove / 2, y: 0, width: max(0.4, 1 * depth), height: size.height)),
                with: .color(Color.white.opacity(0.1 + 0.4 * Double(depth))))
        }
        // The cylinder's curve top to bottom: a lit band high on it, shade below.
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.35), location: 0), .init(color: .white.opacity(0.22), location: 0.3),
                    .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.55), location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }
}
