import SwiftUI

/// A lens ring seen from the side, for the Record page: a black barrel with a scale engraved in
/// lens-maker's yellow that turns under a fixed index mark, above a knurled grip band. Drag
/// along it to turn it. The scale wraps round the barrel, so marks narrow and dim towards its
/// edges. It lies across the screen upright; `vertical` stands it up beside the picture when
/// the phone is held sideways, where the left hand turns it like a real lens.
struct LensRing: View {
    struct Mark: Hashable {
        let position: Double
        /// Engraved beside the tick; unlabelled marks are the small ticks between.
        let label: String?
    }

    let title: String
    let readout: String
    let marks: [Mark]
    let range: ClosedRange<Double>
    /// How far the barrel turns for one unit of position.
    let degreesPerUnit: Double
    let value: Double
    var vertical = false
    var enabled = true
    let onChange: (Double) -> Void
    var onEnd: (Double) -> Void = { _ in }

    @State private var dragStart: Double?

    static let engraving = Color(hex: 0xE6C24C)

    var body: some View {
        GeometryReader { geo in
            let length = vertical ? geo.size.height : geo.size.width
            let thickness = vertical ? geo.size.width : geo.size.height
            barrel
                .frame(width: length, height: thickness)
                .rotationEffect(.degrees(vertical ? -90 : 0))
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(turn(length: length))
        }
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1)
        }
    }

    // MARK: Turning

    private func turn(length: CGFloat) -> some Gesture {
        // Under the index, the barrel's surface moves this far for one unit.
        let pointsPerUnit = Double(length / 2) * degreesPerUnit * .pi / 180
        func position(_ g: DragGesture.Value) -> Double {
            // Upright the scale reads left to right; stood up, bottom to top. It follows the
            // finger, so drawing it back brings the marks beyond the index under it.
            let along = vertical ? -g.translation.height : g.translation.width
            return min(range.upperBound, max(range.lowerBound, (dragStart ?? value) - along / pointsPerUnit))
        }
        return DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragStart == nil { dragStart = value }
                let next = position(g)
                if crossesMark(from: value, to: next) { Haptics.detent() }
                onChange(next)
            }
            .onEnded { g in
                let last = position(g)
                dragStart = nil
                onEnd(last)
            }
    }

    private func crossesMark(from a: Double, to b: Double) -> Bool {
        marks.contains { $0.label != nil && min(a, b) < $0.position && $0.position <= max(a, b) }
    }

    /// The next engraved mark up or down from where the ring is.
    private func step(_ direction: Int) {
        let labelled = marks.filter { $0.label != nil }.map(\.position)
        let next =
            direction > 0
            ? labelled.filter { $0 > value + 0.001 }.min()
            : labelled.filter { $0 < value - 0.001 }.max()
        guard let next else { return }
        onChange(next)
        onEnd(next)
    }

    // MARK: Barrel

    private var barrel: some View {
        Canvas { context, size in
            let radius = size.width / 2
            let knurlTop = (size.height * 0.62).rounded()
            let perUnit = degreesPerUnit * .pi / 180
            // A point θ round the barrel from the index sits r·sin θ from the middle.
            func x(_ theta: Double) -> CGFloat { radius + radius * CGFloat(sin(theta)) }

            for mark in marks {
                let theta = (mark.position - value) * perUnit
                guard abs(theta) < .pi / 2 else { continue }
                let facing = cos(theta)
                let px = x(theta)
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: 1))
                tick.addLine(to: CGPoint(x: px, y: mark.label == nil ? 4 : 7))
                context.stroke(
                    tick, with: .color(Self.engraving.opacity(0.9 * facing)), lineWidth: max(0.5, 1.2 * facing))
                if let label = mark.label {
                    var engraved = context
                    engraved.translateBy(x: px, y: (1 + 7 + knurlTop) / 2 + 1)
                    engraved.scaleBy(x: facing, y: 1)
                    engraved.opacity = pow(facing, 0.6)
                    let text = Text(label).font(Theme.mono(10, weight: .bold)).foregroundColor(Self.engraving)
                    engraved.draw(text, at: .zero, anchor: .center)
                }
            }

            // The knurled grip: ridges round the barrel that turn with it.
            let band = CGRect(x: 0, y: knurlTop, width: size.width, height: size.height - knurlTop)
            context.fill(Path(band), with: .color(.black.opacity(0.35)))
            let pitch = 6.5 * .pi / 180
            let offset = (value * perUnit).truncatingRemainder(dividingBy: pitch)
            for k in -15...15 {
                let theta = Double(k) * pitch - offset
                guard abs(theta) < .pi / 2 else { continue }
                let facing = CGFloat(cos(theta))
                let shadowTheta = min(.pi / 2, theta + pitch * 0.4)
                for (at, color, width) in [
                    (x(theta), Color.white.opacity(0.24 * facing), 1.3 * facing),
                    (x(shadowTheta), Color.black.opacity(0.7), 1.1 * facing),
                ] {
                    var ridge = Path()
                    ridge.move(to: CGPoint(x: at, y: knurlTop + 1.5))
                    ridge.addLine(to: CGPoint(x: at, y: size.height - 1.5))
                    context.stroke(ridge, with: .color(color), lineWidth: max(0.4, width))
                }
            }
            var seam = Path()
            seam.move(to: CGPoint(x: 0, y: knurlTop))
            seam.addLine(to: CGPoint(x: size.width, y: knurlTop))
            context.stroke(seam, with: .color(.black.opacity(0.8)), lineWidth: 1)
        }
        .background(
            // Lit from the upper left, falling away round both sides of the barrel.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: Color(hex: 0x252523), location: 0.18),
                    .init(color: Color(hex: 0x4A4A46), location: 0.42),
                    .init(color: Color(hex: 0x2C2C2A), location: 0.66),
                    .init(color: Color(hex: 0x0B0B0B), location: 0.9),
                    .init(color: .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
        )
        .overlay(alignment: .top) {
            // The fixed index the scale reads against.
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 9, y: 0))
                p.addLine(to: CGPoint(x: 4.5, y: 5))
                p.closeSubpath()
            }
            .fill(Theme.ivory)
            .frame(width: 9, height: 5)
            .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black, lineWidth: 1))
    }
}
