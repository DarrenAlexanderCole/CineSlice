import SwiftUI

/// Sound mode's screen, a small field recorder behind glass: a backlit analyser of the signal
/// with the EQ's curve glowing over it (drag on it to shape a band), and under it a backlit VU
/// meter beside the input, the peak and the headphone monitor key. The EQ's faders are on their
/// own plate, `EQFaceplate`. What's shown and heard is what's recorded, after the EQ.
struct SoundDesk: View {
    let recorder: SoundRecorder
    let isRecording: Bool
    let access: CameraRig.Access

    var body: some View {
        if access == .denied {
            VStack(spacing: 10) {
                Text("MICROPHONE ACCESS IS OFF").font(Theme.mono(11, weight: .bold)).foregroundStyle(Theme.label)
                Text("Turn it on in Settings to record sound.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
            .padding(20)
        } else {
            GeometryReader { geo in
                // Held sideways the meter stands beside the analyser; upright, under it.
                let wide = geo.size.width > geo.size.height * 1.25
                let layout = wide ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
                VStack(spacing: 8) {
                    layout {
                        Analyser(recorder: recorder)
                        meterBridge(wide: wide)
                            .frame(width: wide ? min(220, geo.size.width * 0.4) : nil)
                    }
                    footer
                }
                .padding(.horizontal, 10)
                .padding(.top, 38)
                .padding(.bottom, 8)
            }
        }
    }

    private func meterBridge(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VUMeter(level: recorder.level, peak: recorder.peak)
                .aspectRatio(1.75, contentMode: .fit)
                .frame(maxWidth: 210)
            info
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The input, its peak in backlit figures, and the monitor key.
    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(recorder.inputName.uppercased())
                    .font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.label).lineLimit(1)
                Text(
                    String(
                        format: "%.0f kHz · %@", recorder.sampleRate / 1000, recorder.channels > 1 ? "STEREO" : "MONO")
                )
                .font(Theme.mono(7, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("PEAK").font(Theme.mono(7, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
                Text(recorder.peak > 0 ? String(format: "%.1f dB", recorder.peak * 60 - 60) : "–∞ dB")
                    .font(Theme.mono(13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(recorder.peak > 0.95 ? Theme.playhead : VUMeter.lamp)
                    .shadow(color: (recorder.peak > 0.95 ? Theme.playhead : VUMeter.lamp).opacity(0.6), radius: 4)
            }
            .accessibilityElement(children: .combine)
            Button {
                recorder.setMonitoring(!recorder.isMonitoring)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "headphones").font(.system(size: 11, weight: .semibold))
                    Text("MONITOR").font(Theme.mono(8, weight: .bold))
                }
                .padding(.horizontal, 9)
                .fixedSize()
            }
            .buttonStyle(.instrument(.dark, active: recorder.isMonitoring, height: 28))
            .fixedSize()
            .disabled(!recorder.hasHeadphones)
            .opacity(recorder.hasHeadphones ? 1 : 0.45)
            .accessibilityLabel("Monitor in headphones")
            .accessibilityValue(recorder.isMonitoring ? "On" : "Off")
            .accessibilityHint(
                recorder.hasHeadphones
                    ? "Hear the microphone, after the EQ, in your headphones."
                    : "Plug in headphones to monitor. The speaker would feed back into the microphone.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        Text(status)
            .font(Theme.mono(8, weight: .bold))
            .foregroundStyle(isRecording ? Theme.playhead : Theme.secondaryLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var status: String {
        if isRecording { return recorder.isEQOn ? "RECORDING · THROUGH THE EQ" : "RECORDING · EQ OFF" }
        if !recorder.hasHeadphones { return "PLUG IN HEADPHONES TO MONITOR · TAKES GO IN THE BIN" }
        return "SOUND ONLY · TAKES GO IN THE BIN"
    }
}

// MARK: - Analyser

/// The spectrum as a smooth, softly filled trace on a faint grid, 20 Hz to 20 kHz, with the EQ's
/// curve over it in glowing Signal on a ±12 dB scale and a node at each band (lit when it's
/// moved). Dragging up or down on it sets the nearest band.
private struct Analyser: View {
    let recorder: SoundRecorder

    @State private var dragBand: Int?

    private static let low: Float = 20
    private static let high: Float = 20_000

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 8)
                .offsetBy(dx: 0, dy: -4)
            Canvas { context, size in
                drawGrid(&context, plot: plot, size: size)
                drawSpectrum(&context, plot: plot)
                drawCurve(&context, plot: plot)
            }
            .contentShape(Rectangle())
            .gesture(shape(plot: plot))
        }
        .background(
            ZStack {
                Color(hex: 0x0B0D0B)
                // Lit from below the glass, faintly, in Signal.
                RadialGradient(
                    colors: [Theme.signal.opacity(0.09), .clear], center: .bottom, startRadius: 0, endRadius: 260)
            }
        )
        .recessed(cornerRadius: 8)
        .accessibilityElement()
        .accessibilityLabel("Spectrum analyser")
        .accessibilityValue(recorder.isEQOn ? "With the EQ's curve" : "EQ off")
    }

    private func x(_ hz: Float, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(log(hz / Self.low) / log(Self.high / Self.low)) * plot.width
    }

    private func y(db: Float, _ plot: CGRect) -> CGFloat {
        let range = SoundRecorder.gainRange.upperBound
        return plot.midY - CGFloat(max(-range, min(range, db)) / range) * (plot.height / 2 - 4)
    }

    private func drawGrid(_ context: inout GraphicsContext, plot: CGRect, size: CGSize) {
        let decades: [Float] = [100, 1_000, 10_000]
        for hz: Float in [50, 200, 500, 2_000, 5_000] + decades {
            let px = x(hz, plot)
            context.stroke(
                Path {
                    $0.move(to: CGPoint(x: px, y: plot.minY))
                    $0.addLine(to: CGPoint(x: px, y: plot.maxY))
                },
                with: .color(Theme.ivory.opacity(decades.contains(hz) ? 0.1 : 0.045)), lineWidth: 0.5)
        }
        for db: Float in [-12, -6, 0, 6, 12] {
            let py = y(db: db, plot)
            context.stroke(
                Path {
                    $0.move(to: CGPoint(x: plot.minX, y: py))
                    $0.addLine(to: CGPoint(x: plot.maxX, y: py))
                },
                with: .color(Theme.ivory.opacity(db == 0 ? 0.16 : 0.05)), lineWidth: 0.5)
            if db != 0 {
                context.draw(
                    Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(Theme.mono(6, weight: .bold))
                        .foregroundStyle(Theme.aluminum.opacity(0.45)),
                    at: CGPoint(x: plot.maxX - 1, y: py - 1), anchor: .bottomTrailing)
            }
        }
        let labels: [(Float, String)] = [
            (50, "50"), (100, "100"), (500, "500"), (1_000, "1K"), (5_000, "5K"),
            (10_000, "10K"),
        ]
        for (hz, label) in labels {
            context.draw(
                Text(label).font(Theme.mono(6, weight: .bold)).foregroundStyle(Theme.aluminum.opacity(0.55)),
                at: CGPoint(x: x(hz, plot) + 2, y: size.height - 2), anchor: .bottomLeading)
        }
    }

    /// The spectrum: a soft ivory haze rising from the floor, edged with a fine line.
    private func drawSpectrum(_ context: inout GraphicsContext, plot: CGRect) {
        let points = zip(SoundRecorder.columnFrequencies, recorder.spectrum).map { hz, value in
            CGPoint(x: x(hz, plot), y: plot.maxY - CGFloat(value) * plot.height)
        }
        guard points.count > 1 else { return }
        let trace = Self.smooth(points)
        var fill = trace
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: plot.maxY))
        fill.addLine(to: CGPoint(x: points[0].x, y: plot.maxY))
        fill.closeSubpath()
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [Theme.ivory.opacity(0.26), Theme.ivory.opacity(0.03)]),
                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        context.stroke(trace, with: .color(Theme.ivory.opacity(0.5)), lineWidth: 0.8)
    }

    /// The EQ's curve, glowing, its lift and cut washed in Signal, and a node on each band.
    private func drawCurve(_ context: inout GraphicsContext, plot: CGRect) {
        let on = recorder.isEQOn
        let steps = max(2, Int(plot.width / 2))
        let curve = Path { path in
            for i in 0...steps {
                let hz = Self.low * pow(Self.high / Self.low, Float(i) / Float(steps))
                let point = CGPoint(x: x(hz, plot), y: y(db: recorder.response(at: hz), plot))
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
        let zero = y(db: 0, plot)
        var wash = curve
        wash.addLine(to: CGPoint(x: plot.maxX, y: zero))
        wash.addLine(to: CGPoint(x: plot.minX, y: zero))
        wash.closeSubpath()
        let color = on ? Theme.signal : Theme.aluminum.opacity(0.5)
        context.fill(wash, with: .color(color.opacity(0.13)))
        var glow = context
        glow.addFilter(.blur(radius: 4))
        glow.stroke(curve, with: .color(color.opacity(0.55)), lineWidth: 4)
        context.stroke(curve, with: .color(color), lineWidth: 1.6)

        for (i, hz) in SoundRecorder.bands.enumerated() {
            let center = CGPoint(x: x(hz, plot), y: y(db: on ? recorder.response(at: hz) : 0, plot))
            let moved = recorder.gains[i] != 0 && on
            let r: CGFloat = dragBand == i ? 6 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            if moved {
                var halo = context
                halo.addFilter(.blur(radius: 3))
                halo.fill(dot, with: .color(Theme.signal.opacity(0.8)))
            }
            context.fill(dot, with: .color(moved ? Theme.signal : Color(hex: 0x0B0D0B)))
            context.stroke(dot, with: .color(color.opacity(moved ? 1 : 0.7)), lineWidth: 1.2)
        }
    }

    /// Up and down on the analyser sets the band nearest where the finger came down.
    private func shape(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard recorder.isEQOn else { return }
                if dragBand == nil {
                    dragBand = SoundRecorder.bands.indices.min {
                        abs(x(SoundRecorder.bands[$0], plot) - g.startLocation.x)
                            < abs(x(SoundRecorder.bands[$1], plot) - g.startLocation.x)
                    }
                    Haptics.press()
                }
                guard let band = dragBand else { return }
                let range = SoundRecorder.gainRange.upperBound
                let db = Float((plot.midY - g.location.y) / (plot.height / 2 - 4)) * range
                let next = abs(db) < 0.8 ? 0 : db.rounded()
                if next != recorder.gains[band] {
                    if next == 0 { Haptics.detent() }
                    recorder.setGain(next, band: band)
                }
            }
            .onEnded { _ in
                if dragBand != nil { recorder.save() }
                dragBand = nil
            }
    }

    /// A smooth line through the points (Catmull-Rom as Bézier curves).
    static func smooth(_ points: [CGPoint]) -> Path {
        Path { path in
            path.move(to: points[0])
            for i in 0..<(points.count - 1) {
                let p0 = points[max(0, i - 1)]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[min(points.count - 1, i + 2)]
                path.addCurve(
                    to: p2,
                    control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                    control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
        }
    }
}

// MARK: - VU meter

/// A VU meter after the old studio ones: a dark face lit warm from below, a brass scale from
/// −20 to +3 with the red over 0, and an ivory needle. 0 VU sits at −18 dBFS, the usual
/// alignment; the scale is spaced as a real one is, by signal, not by dB. A lamp lights for
/// peaks near clipping.
struct VUMeter: View {
    let level: Float
    let peak: Float

    static let lamp = Color(hex: 0xFFB54A)
    private static let scale = Color(hex: 0xE3B866)
    private static let sweep = 46.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pivot = CGPoint(x: size.width / 2, y: size.height * 1.12)
            let radius = size.height * 0.86
            ZStack {
                face
                Canvas { context, _ in drawScale(&context, size: size, pivot: pivot, radius: radius) }
                Needle(angle: needleAngle, pivot: pivot, length: radius + 6)
                    .stroke(Theme.ivory, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .shadow(color: .black.opacity(0.8), radius: 1.5, x: 1.5, y: 2)
                    .animation(.interpolatingSpring(stiffness: 140, damping: 16), value: needleAngle)
                // The lamp for peaks.
                Circle()
                    .fill(peak > 0.95 ? Theme.playhead : Theme.playhead.opacity(0.15))
                    .frame(width: 5, height: 5)
                    .shadow(color: peak > 0.95 ? Theme.playhead : .clear, radius: 4)
                    .position(x: size.width - 10, y: 10)
                // Glass.
                LinearGradient(
                    colors: [Color.white.opacity(0.1), .clear, .clear], startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .padding(5)
        .background(bezel)
        .accessibilityElement()
        .accessibilityLabel("VU meter")
        .accessibilityValue(String(format: "%.0f VU", vu))
    }

    /// The signal in VU: dBFS plus 18.
    private var vu: Double { Double(level) * 60 - 60 + 18 }

    private static func angle(vu: Double) -> Double {
        let fraction = pow(10, vu / 20) / pow(10, 3.0 / 20)
        return -sweep + 2 * sweep * min(1.04, max(-0.02, fraction))
    }

    private var needleAngle: Double { level <= 0 ? -Self.sweep - 1 : Self.angle(vu: vu) }

    private var face: some View {
        ZStack {
            Color(hex: 0x100D09)
            RadialGradient(
                colors: [Self.lamp.opacity(0.42), Self.lamp.opacity(0.12), .clear], center: UnitPoint(x: 0.5, y: 1.05),
                startRadius: 0, endRadius: 130)
        }
    }

    private var bezel: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x2A2B27), Color(hex: 0x0C0C0B)], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.black.opacity(0.6)], startPoint: .top,
                            endPoint: .bottom), lineWidth: 1)
            )
            .overlay(
                // The face's inset lip.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.black, lineWidth: 1.5)
                    .padding(4)
            )
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
    }

    private func drawScale(_ context: inout GraphicsContext, size: CGSize, pivot: CGPoint, radius: CGFloat) {
        func point(_ degrees: Double, _ r: CGFloat) -> CGPoint {
            let t = degrees * .pi / 180
            return CGPoint(x: pivot.x + r * CGFloat(sin(t)), y: pivot.y - r * CGFloat(cos(t)))
        }
        func arc(from a: Double, to b: Double, r: CGFloat) -> Path {
            Path { path in
                path.addArc(
                    center: pivot, radius: r, startAngle: .degrees(a - 90), endAngle: .degrees(b - 90),
                    clockwise: false)
            }
        }
        let zero = Self.angle(vu: 0)
        context.stroke(arc(from: Self.angle(vu: -20), to: zero, r: radius), with: .color(Self.scale), lineWidth: 1.2)
        context.stroke(
            arc(from: zero, to: Self.angle(vu: 3), r: radius + 1.5), with: .color(Theme.playhead), lineWidth: 3)
        context.stroke(
            arc(from: Self.angle(vu: -20), to: zero, r: radius - 3), with: .color(Self.scale.opacity(0.85)),
            lineWidth: 2.5)

        let labelSize = max(6, min(9, size.height * 0.09))
        let marks: [(Double, String)] = [
            (-20, "20"), (-10, "10"), (-7, "7"), (-5, "5"), (-3, "3"), (-2, "2"), (-1, "1"), (0, "0"), (1, "1"),
            (2, "2"), (3, "3"),
        ]
        for (vu, label) in marks {
            let a = Self.angle(vu: vu)
            let color = vu > 0 ? Theme.playhead : Self.scale
            context.stroke(
                Path {
                    $0.move(to: point(a, radius))
                    $0.addLine(to: point(a, radius + 5))
                }, with: .color(color),
                lineWidth: 1)
            context.draw(
                Text(label).font(.system(size: labelSize, weight: .semibold)).foregroundStyle(color),
                at: point(a, radius + 5 + labelSize * 0.9), anchor: .center)
        }
        // Percent of the reference level, with dots, under the arc.
        if size.height > 70 {
            for percent in [20.0, 40, 60, 80, 100] {
                let a = -Self.sweep + 2 * Self.sweep * percent / (100 * pow(10, 3.0 / 20))
                context.fill(
                    Path(ellipseIn: CGRect(origin: point(a, radius - 8), size: .zero).insetBy(dx: -1, dy: -1)),
                    with: .color(Self.scale.opacity(0.85)))
                context.draw(
                    Text(percent == 100 ? "100%" : "\(Int(percent))")
                        .font(.system(size: labelSize * 0.7, weight: .semibold))
                        .foregroundStyle(Self.scale.opacity(0.85)),
                    at: point(a, radius - 8 - labelSize), anchor: .center)
            }
        }
        context.draw(
            Text("VU").font(.system(size: labelSize * 1.5, weight: .medium)).foregroundStyle(Self.scale),
            at: CGPoint(x: size.width / 2, y: size.height * 0.74), anchor: .center)
        context.draw(
            Text("−").font(.system(size: labelSize * 1.2, weight: .bold)).foregroundStyle(Self.scale),
            at: point(-Self.sweep - 3, radius - 10), anchor: .center)
        context.draw(
            Text("+").font(.system(size: labelSize * 1.2, weight: .bold)).foregroundStyle(Theme.playhead),
            at: point(Self.sweep + 3, radius - 10), anchor: .center)
    }
}

/// The meter's needle, turning about its pivot below the face; animatable, so it swings.
private struct Needle: Shape {
    var angle: Double
    let pivot: CGPoint
    let length: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = angle * .pi / 180
        return Path { path in
            path.move(to: pivot)
            path.addLine(to: CGPoint(x: pivot.x + length * CGFloat(sin(t)), y: pivot.y - length * CGFloat(cos(t))))
        }
    }
}

// MARK: - EQ faceplate

/// The graphic EQ on a brushed graphite plate screwed to the deck: ten faders an octave apart
/// and a trim, each in a slot cut into an inset well with its scale lit from behind, an LED over
/// each band that's moved, and keys to switch the EQ off to compare and to set it flat.
struct EQFaceplate: View {
    let recorder: SoundRecorder

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                EngravedLabel("Graphic EQ")
                Text("10 BAND · ±12 dB")
                    .font(Theme.mono(7, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.aluminum.opacity(0.5))
                    .shadow(color: .black.opacity(0.7), radius: 0, y: -0.8)
                Spacer(minLength: 4)
                Button {
                    recorder.setEQOn(!recorder.isEQOn)
                    recorder.save()
                } label: {
                    HStack(spacing: 5) {
                        LED(isOn: recorder.isEQOn)
                        Text("EQ").font(Theme.mono(8, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .fixedSize()
                }
                .buttonStyle(.instrument(.dark, active: recorder.isEQOn, height: 24))
                .fixedSize()
                .accessibilityLabel("EQ on")
                .accessibilityValue(recorder.isEQOn ? "On" : "Off")
                Button {
                    recorder.flatten()
                    recorder.save()
                } label: {
                    Text("FLAT").font(Theme.mono(8, weight: .bold)).padding(.horizontal, 9).fixedSize()
                }
                .buttonStyle(.instrument(.dark, height: 24))
                .fixedSize()
                .disabled(recorder.gains.allSatisfy { $0 == 0 })
                .accessibilityHint("Sets every band back to 0 dB.")
            }
            .padding(.horizontal, 14)
            HStack(spacing: 0) {
                ForEach(SoundRecorder.bands.indices, id: \.self) { band in
                    let label = Self.label(SoundRecorder.bands[band])
                    BandSlot(
                        label: label, value: recorder.gains[band], accessibilityName: "\(label) hertz",
                        onChange: { recorder.setGain($0, band: band) }, onCommit: { recorder.save() })
                }
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.black, Color.white.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: 2)
                    .padding(.vertical, 6)
                BandSlot(
                    label: "TRIM", value: recorder.trim, accessibilityName: "Trim", isTrim: true,
                    onChange: { recorder.setTrim($0) }, onCommit: { recorder.save() })
            }
            .disabled(!recorder.isEQOn)
            .opacity(recorder.isEQOn ? 1 : 0.55)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .recessed(cornerRadius: 10)
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(plate)
    }

    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return
            shape
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x434B3A), Theme.instrument, Color(hex: 0x1F241C)], startPoint: .top,
                    endPoint: .bottom)
            )
            .overlay(BrushedMetal(strength: 0.9).clipShape(shape))
            .overlay(Grain(opacity: 0.45).clipShape(shape))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.04), Color.black.opacity(0.5)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) { Screw(angle: 25).padding(4) }
            .overlay(alignment: .topTrailing) { Screw(angle: -40).padding(4) }
            .overlay(alignment: .bottomLeading) { Screw(angle: 70).padding(4) }
            .overlay(alignment: .bottomTrailing) { Screw(angle: 10).padding(4) }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }

    static func label(_ hz: Float) -> String {
        hz >= 1_000 ? "\(Int(hz / 1_000))K" : "\(Int(hz))"
    }
}

/// One band's fader, standing up in a slot: a scale lit from behind beside it (0 dB brightest),
/// the slot glowing in Signal from 0 dB to the cap, and a machined cap with a Signal index.
/// Drags move it from where it was in whole dB, catching at 0; a double tap puts it back to 0.
private struct BandSlot: View {
    let label: String
    let value: Float
    let accessibilityName: String
    var isTrim = false
    let onChange: (Float) -> Void
    let onCommit: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var start: Float?

    private let capHeight: CGFloat = 13

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Circle()
                    .fill(value != 0 ? glow : Color.black.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .shadow(color: value != 0 ? glow : .clear, radius: 3)
                Text(value == 0 ? "0" : String(format: "%+.0f", value))
                    .font(Theme.mono(7, weight: .bold))
                    .foregroundStyle(start != nil || value != 0 ? glow : Theme.aluminum.opacity(0.6))
                    .monospacedDigit()
                    .fixedSize()
            }
            GeometryReader { geo in
                let travel = max(1, geo.size.height - capHeight)
                let range = SoundRecorder.gainRange
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let capY = (1 - fraction) * travel
                let mid = capHeight / 2 + travel / 2
                ZStack(alignment: .top) {
                    // The backlit scale either side of the slot.
                    ForEach([0, 0.25, 0.5, 0.75, 1] as [CGFloat], id: \.self) { mark in
                        HStack(spacing: 8) {
                            tick(mark)
                            tick(mark)
                        }
                        .offset(y: capHeight / 2 + mark * travel - 0.5)
                    }
                    // The slot.
                    Capsule()
                        .fill(Color.black.shadow(.inner(color: .black, radius: 1.5, y: 1)))
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.black, Color.white.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.5)
                        )
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                    // Light through the slot, from 0 dB to the cap.
                    Capsule()
                        .fill(glow.opacity(isEnabled ? 0.95 : 0.3))
                        .frame(width: 2, height: abs(capY + capHeight / 2 - mid))
                        .shadow(color: glow.opacity(0.9), radius: 3)
                        .offset(y: min(capY + capHeight / 2, mid))
                    cap.offset(y: capY)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(travel: travel))
                .onTapGesture(count: 2) {
                    onChange(0)
                    onCommit()
                    Haptics.detent()
                }
            }
            Text(label)
                .font(Theme.mono(7, weight: .heavy))
                .foregroundStyle(isTrim ? Theme.brass : Theme.aluminum.opacity(0.85))
                .shadow(color: .black.opacity(0.7), radius: 0, y: -0.8)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(String(format: "%+.0f decibels", value))
        .accessibilityAdjustableAction { direction in
            onChange(value + (direction == .increment ? 1 : -1))
            onCommit()
        }
    }

    private var glow: Color { isTrim ? Theme.brass : Theme.signal }

    private func tick(_ mark: CGFloat) -> some View {
        Rectangle()
            .fill(glow.opacity(mark == 0.5 ? 0.75 : 0.28))
            .frame(width: mark == 0.5 ? 5 : 3, height: 1)
            .shadow(color: mark == 0.5 ? glow.opacity(0.6) : .clear, radius: 2)
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Theme.ivory, Theme.aluminum, Color(hex: 0x7F8177)], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                VStack(spacing: 2) {
                    Rectangle().fill(Color.black.opacity(0.22)).frame(height: 0.6)
                    Rectangle().fill(glow).frame(height: 1.5).shadow(color: glow, radius: 1.5)
                    Rectangle().fill(Color.black.opacity(0.22)).frame(height: 0.6)
                }
                .padding(.horizontal, 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.85), Color.black.opacity(0.45)], startPoint: .top,
                            endPoint: .bottom), lineWidth: 0.7)
            )
            .frame(width: 20, height: capHeight)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 2)
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                guard isEnabled else { return }
                if start == nil {
                    start = value
                    Haptics.press()
                }
                let range = SoundRecorder.gainRange
                let span = range.upperBound - range.lowerBound
                let raw = (start ?? value) - Float(g.translation.height / travel) * span
                // Whole dB steps, with a little catch at 0.
                var next = min(range.upperBound, max(range.lowerBound, raw.rounded()))
                if abs(raw) < 0.8 { next = 0 }
                if next != value {
                    if next == 0 || (value < 0) != (next < 0) { Haptics.detent() }
                    onChange(next)
                }
            }
            .onEnded { _ in
                start = nil
                onCommit()
            }
    }
}
