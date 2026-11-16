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
