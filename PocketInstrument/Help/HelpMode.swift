import SwiftUI

/// Help mode: while it's on, every control marked with `helpTopic(_:)` gets a faint Signal outline,
/// and a tap on it shows its card (`HelpCard`) instead of using it. The "?" key in the top bar
/// turns it on and off; the help bar offers the manual.
@MainActor
@Observable
final class HelpCenter {
    var isOn = false
    /// The card showing, if any.
    var shown: HelpTopic?

    func toggle() {
        isOn.toggle()
        shown = nil
        Haptics.tap()
    }
}

extension EnvironmentValues {
    /// nil where there's no help mode (the Library), so marked controls behave as usual.
    @Entry var helpCenter: HelpCenter?
}

extension View {
    /// Marks a control for help mode: outlined while help is on, and a tap shows its card.
    /// Mark controls, not containers of other marked controls: an outer mark sits on top of
    /// the inner ones and would catch their taps.
    func helpTopic(_ topic: HelpTopic) -> some View {
        modifier(HelpTarget(topic: topic))
    }
}

private struct HelpTarget: ViewModifier {
    let topic: HelpTopic
    @Environment(\.helpCenter) private var help

    /// The outline sits over the control, so the control itself gets no touches (drags included)
    /// while help is on; scrolling whatever contains it still works.
    func body(content: Content) -> some View {
        content.overlay {
            if let help, help.isOn {
                let isShown = help.shown == topic
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.signal.opacity(isShown ? 1 : 0.45), lineWidth: isShown ? 2 : 1)
                    .background(Theme.signal.opacity(isShown ? 0.12 : 0.001))  // nearly clear, but takes the tap
                    .shadow(color: Theme.signal.opacity(isShown ? 0.6 : 0), radius: 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        help.shown = topic
                        Haptics.detent()
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(topic.title), help")
                    .accessibilityHint("Shows what this control does.")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

/// The "?" key: lit while help mode is on.
struct HelpKey: View {
    var help: HelpCenter

    var body: some View {
        Button {
            help.toggle()
        } label: {
            Image(systemName: "questionmark")
        }
        .buttonStyle(.instrument(active: help.isOn, height: 36))
        .accessibilityLabel("Help")
        .accessibilityValue(help.isOn ? "On" : "Off")
        .accessibilityHint("While on, tapping a control explains it instead of using it.")
    }
}

/// Across the top of the viewer while help is on: what to do, the manual, and Done.
struct HelpBar: View {
    var help: HelpCenter

    var body: some View {
        HStack(spacing: 8) {
            LED(isOn: true)
            VStack(alignment: .leading, spacing: 0) {
                Text("HELP").font(Theme.mono(10, weight: .bold)).foregroundStyle(Theme.signal)
                Text("Tap any control").font(Theme.caption).foregroundStyle(Theme.label)
            }
            Spacer(minLength: 4)
            ManualLink(compact: true)
            Button("Done") { help.toggle() }
                .buttonStyle(.instrument(.key, height: 32))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.signal.opacity(0.4)))
        )
        .environment(\.colorScheme, .dark)
    }
}

/// The shown topic's card: its page, title and explanation, over smoked glass.
struct HelpCard: View {
    var help: HelpCenter
    var topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(topic.page.title.uppercased())
                    .font(Theme.mono(9, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
                Spacer()
                Button {
                    help.shown = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.label)
                .accessibilityLabel("Close")
            }
            Text(topic.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.signal)
            Text(topic.body)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ivory)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.signal.opacity(0.5))
                )
                .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

extension View {
    /// Shows the help card for the tapped control at `alignment` while help mode is on.
    func helpCardOverlay(_ help: HelpCenter?, alignment: Alignment) -> some View {
        overlay(alignment: alignment) {
            if let help, help.isOn, let topic = help.shown {
                HelpCard(help: help, topic: topic)
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: alignment == .top ? .top : .bottom)))
                    .id(topic)
            }
        }
        .animation(.easeOut(duration: 0.18), value: help?.shown)
    }
}

/// Shares the PDF manual: save it to Files, AirDrop, Mail or print it.
struct ManualLink: View {
    var compact = false

    var body: some View {
        if let url = HelpManual.url {
            ShareLink(item: url) {
                if compact { Image(systemName: "book") } else { Label("Manual", systemImage: "book") }
            }
            .buttonStyle(.instrument(height: compact ? 32 : 36))
            .accessibilityLabel("Manual")
            .accessibilityHint("Shares the CineSlice manual as a PDF, to save, print or send.")
        }
    }
}
