import EditCore
import SwiftUI

/// The master EQ on the Audio page: its curve over the spectrum, a knob for each setting (low cut,
/// low, mid frequency, mid gain, mid width, high) and keys to switch it off to compare or set it
/// flat. Turning a knob is heard at once; letting go is one undo step.
struct MasterEQPanel: View {
    var model: WorkspaceModel

    /// The settings while a knob is being turned.
    @State private var live: MasterEQ?

    var body: some View {
        let eq = live ?? model.project.masterEQ
        PanelSection(title: "Master EQ · whole mix") {
            EQCurve(eq: eq)
                .frame(height: 64)
            HStack(spacing: 0) {
                knob("LOW CUT", eq, \.lowCut, LogScale(MasterEQ.lowCutRange), reset: 0) { pos, hz in
                    pos == 0 ? "OFF" : Self.hertz(hz)
                }
                gainKnob("LOW", eq, \.lowGain)
                knob("MID", eq, \.midFrequency, LogScale(MasterEQ.midFrequencyRange), reset: LogScale(MasterEQ.midFrequencyRange).position(of: 1_000)) {
                    Self.hertz($1)
                }
                gainKnob("MID GAIN", eq, \.midGain)
                knob("WIDTH", eq, \.midWidth, LogScale(MasterEQ.midWidthRange), reset: LogScale(MasterEQ.midWidthRange).position(of: 1)) {
                    String(format: "%.1f oct", $1)
                }
                gainKnob("HIGH", eq, \.highGain)
            }
            .disabled(!eq.isOn)
            HStack(spacing: 6) {
                Button {
                    var next = model.project.masterEQ
                    next.isOn.toggle()
                    model.setMasterEQ(next)
                } label: {
                    key("EQ ON", eq.isOn ? "Tap to hear it off" : "Off: the mix as it is")
                }
                .buttonStyle(OptionKeyStyle(isOn: eq.isOn))
                .accessibilityLabel("EQ on")
                .accessibilityValue(eq.isOn ? "On" : "Off")
                Button {
                    var flat = MasterEQ.flat
                    flat.isOn = model.project.masterEQ.isOn
                    model.setMasterEQ(flat)
                } label: {
                    key("FLAT", "Every band back to 0")
                }
                .buttonStyle(OptionKeyStyle(isOn: false))
                .disabled(model.project.masterEQ.filters(sampleRate: 44_100).isEmpty)
                .accessibilityLabel("Flat")
                .accessibilityHint("Sets every band back to no change.")
            }
        }
    }

    private func key(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.label)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryLabel)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func gainKnob(_ title: String, _ eq: MasterEQ, _ setting: WritableKeyPath<MasterEQ, Double>) -> some View {
        knob(title, eq, setting, LinearScale(MasterEQ.gainRange), reset: 0.5, detent: 0.5) { _, db in
            abs(db) < 0.05 ? "0 dB" : String(format: "%+.1f dB", db)
        }
    }

    private func knob(
        _ title: String, _ eq: MasterEQ, _ setting: WritableKeyPath<MasterEQ, Double>, _ scale: some KnobScale,
        reset: Double, detent: Double? = nil, text: @escaping (Double, Double) -> String
    ) -> some View {
        func with(_ position: Double) -> MasterEQ {
            var next = live ?? model.project.masterEQ
            next[keyPath: setting] = scale.value(at: position)
            return next
        }
        return Knob(
            title: title, value: scale.position(of: eq[keyPath: setting]), detent: detent, reset: reset,
            text: { text($0, scale.value(at: $0)) },
            onChange: { position in
                let next = with(position)
                live = next
                model.previewEQ(next)
            },
            onCommit: { position in
                let next = with(position)
                live = nil
                model.setMasterEQ(next)
            })
    }

    static func hertz(_ hz: Double) -> String {
        hz >= 1_000 ? String(format: hz >= 9_950 ? "%.0f kHz" : "%.1f kHz", hz / 1_000) : "\(Int(hz.rounded())) Hz"
    }
}

/// How a knob's travel maps onto a setting.
protocol KnobScale {
    func value(at position: Double) -> Double
    func position(of value: Double) -> Double
}

/// Even steps, for gains.
struct LinearScale: KnobScale {
    let range: ClosedRange<Double>
    init(_ range: ClosedRange<Double>) { self.range = range }
    func value(at position: Double) -> Double { range.lowerBound + position * (range.upperBound - range.lowerBound) }
    func position(of value: Double) -> Double {
        min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
}

/// Even ratios, as the ear hears pitch, for frequencies and widths.
struct LogScale: KnobScale {
    let range: ClosedRange<Double>
    init(_ range: ClosedRange<Double>) { self.range = range }
    func value(at position: Double) -> Double { range.lowerBound * pow(range.upperBound / range.lowerBound, position) }
    func position(of value: Double) -> Double {
        min(max(log(value / range.lowerBound) / log(range.upperBound / range.lowerBound), 0), 1)
    }
}

/// The EQ's effect over 20 Hz–20 kHz, ±12 dB, on a faint grid: what the knobs are doing to the
/// sound, at a glance.
private struct EQCurve: View {
    let eq: MasterEQ

    private static let low = 20.0
    private static let high = 20_000.0
    private static let range = 12.0

    var body: some View {
        Canvas { context, size in
            func x(_ hz: Double) -> CGFloat { CGFloat(log(hz / Self.low) / log(Self.high / Self.low)) * size.width }
            func y(_ db: Double) -> CGFloat {
                size.height / 2 - CGFloat(max(min(db, Self.range), -Self.range) / Self.range) * (size.height / 2 - 3)
            }
            for hz in [100.0, 1_000, 10_000] {
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x(hz), y: 0)); $0.addLine(to: CGPoint(x: x(hz), y: size.height)) },
                    with: .color(Theme.hairline), lineWidth: 0.5)
                context.draw(
                    Text(hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))")
                        .font(Theme.mono(8)).foregroundStyle(Theme.secondaryLabel.opacity(0.7)),
                    at: CGPoint(x: x(hz) + 3, y: size.height - 2), anchor: .bottomLeading)
            }
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: y(0))); $0.addLine(to: CGPoint(x: size.width, y: y(0))) },
                with: .color(Theme.hairline), lineWidth: 0.5)
            let steps = max(2, Int(size.width / 2))
            let curve = Path { path in
                for i in 0...steps {
                    let hz = Self.low * pow(Self.high / Self.low, Double(i) / Double(steps))
                    let point = CGPoint(x: x(hz), y: y(eq.isOn ? eq.response(at: hz) : 0))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            context.fill(fill, with: .color(Theme.signal.opacity(eq.isOn ? 0.12 : 0)))
            context.stroke(curve, with: .color(eq.isOn ? Theme.signal : Theme.aluminum.opacity(0.5)), lineWidth: 1.5)
        }
        .padding(6)
        .recessed(cornerRadius: 8)
        .accessibilityHidden(true)
    }
}
