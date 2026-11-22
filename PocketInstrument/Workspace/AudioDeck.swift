import EditCore
import SwiftUI

/// Audio state, in two pages. SPLIT works on each clip's own sound, split on the device: pick a
/// clip in the row, then play it as recorded, or split into voices and everything else with a
/// fader for each (voices down for someone talking behind the camera). Splitting runs once per
/// source in the background and the clip is silent until it's ready. EQ shapes the whole mix
/// (`MasterEQPanel`). Each change is one undo step and never touches the footage. Play and loop
/// to audition it in the sequence.
struct AudioDeck: View {
    var model: WorkspaceModel

    enum Page { case split, eq }
    @State private var page = Page.split

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                pageKey(.split, "SPLIT", "Take sound out of a clip")
                pageKey(.eq, "EQ", "Shape the whole mix")
            }
            if page == .split { AudioClipPicker(model: model) }
            SequenceLane(model: model)
            if page == .split { treatmentPanel } else { MasterEQPanel(model: model) }
            TransportRow(model: model, compact: true) {
                EmptyView()
            } trailing: {
                LoopButton(model: model)
            }
        }
    }

    private func pageKey(_ which: Page, _ title: String, _ detail: String) -> some View {
        Button {
            page = which
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(page == which ? Theme.signal : Theme.label)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .buttonStyle(AudioOptionKeyStyle(isOn: page == which))
        .accessibilityLabel(title == "EQ" ? "Master EQ" : "Split")
    }

    @ViewBuilder
    private var treatmentPanel: some View {
        if let clip = model.selectedClip, let source = model.project.source(for: clip) {
            let number = (model.project.index(ofClip: clip.id) ?? 0) + 1
            PanelSection(title: String(format: "Clip %02d sound", number)) {
                if source.hasAudio {
                    HStack(spacing: 6) {
                        option("Original", "As recorded", isOn: clip.balance == nil, clip) { nil }
                        option("Split", "Voice & everything else", isOn: clip.balance != nil, clip) {
                            clip.balance ?? .removeVoice
                        }
                    }
                    if let balance = clip.balance {
                        HStack(spacing: 14) {
                            Fader(
                                title: "VOICE", value: balance.voice,
                                onChange: { model.applyLevels(balance: SoundBalance(voice: $0, scene: balance.scene)) },
                                onCommit: { model.setSoundBalance(SoundBalance(voice: $0, scene: balance.scene)) }
                            )
                            Fader(
                                title: "EVERYTHING ELSE", value: balance.scene,
                                onChange: { model.applyLevels(balance: SoundBalance(voice: balance.voice, scene: $0)) },
                                onCommit: { model.setSoundBalance(SoundBalance(voice: balance.voice, scene: $0)) }
                            )
                        }
                        .id(clip.id)  // a new clip starts a fresh drag, never inherits another's draft
                        .padding(.horizontal, 4)
                    }
                    status(clip, source)
                } else {
                    Text(source.isStill ? "Photos have no sound." : "This clip has no sound.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                }
            }
        } else {
            Text("Select a clip")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
                .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    private func option(
        _ title: String, _ detail: String, isOn: Bool, _ clip: TimelineClip, balance: @escaping () -> SoundBalance?
    ) -> some View {
        Button {
            model.setSoundBalance(balance())
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.signal : Theme.label)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .buttonStyle(AudioOptionKeyStyle(isOn: isOn))
        .accessibilityLabel(title)
        .accessibilityHint(
            title == "Original"
                ? "Plays the clip's sound as recorded."
                : "Splits the voices from everything else, each with its own level. Starts with the voices out.")
    }

    /// Processing progress, or what the chosen treatment can and can't do.
    @ViewBuilder
    private func status(_ clip: TimelineClip, _ source: SourceAsset) -> some View {
        if let progress = model.voiceProgress[source.id], clip.balance != nil {
            HStack(spacing: 8) {
                LED(isOn: true, blinks: true)
                Text("PROCESSING \(Int(progress * 100))%")
                    .font(Theme.mono(11, weight: .bold))
                    .foregroundStyle(Theme.signal)
                Spacer(minLength: 0)
                Text("Silent until done")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .accessibilityElement(children: .combine)
        } else if let balance = clip.balance, balance.voice == 0, balance.scene > 0 {
            Text("Separated on this iPhone: faint traces of voice may remain.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
        } else {
            Text("Processed on this iPhone. Your footage isn't changed.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
        }
    }
}

/// A compact option key for a row: centred, lit when chosen.
private struct AudioOptionKeyStyle: ButtonStyle {
    var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .background(KeyCap(kind: .dark, isLit: isOn, isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, down in
                if down { Haptics.press() }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The clips in order, each marked with how its sound plays.
private struct AudioClipPicker: View {
    var model: WorkspaceModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                        tile(clip, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .onChange(of: model.selectedClipID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .frame(height: Theme.minTouch + 8)
    }

    private func tile(_ clip: TimelineClip, index: Int) -> some View {
        let isSelected = clip.id == model.selectedClipID
        let midpoint = clip.sourceRange.start + MediaTime(seconds: clip.sourceRange.duration.seconds / 2)
        let hasAudio = model.project.source(for: clip)?.hasAudio ?? false
        return Button {
            model.select(clip.id)
        } label: {
            HStack(spacing: 6) {
                VideoFrameView(url: model.mediaURL(for: clip), time: midpoint.cmTime, maxPixel: 120)
                    .frame(width: 30, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.caption)
                        .foregroundStyle(isSelected ? Theme.signal : Theme.secondaryLabel)
                    Text(badge(clip, hasAudio: hasAudio))
                        .font(Theme.mono(8, weight: .heavy))
                        .foregroundStyle(clip.balance != nil ? Theme.signal : Theme.secondaryLabel)
                }
                .frame(minWidth: 28, alignment: .leading)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.olive.opacity(0.5) : Theme.obsidian)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Theme.signal : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .id(clip.id)
        .accessibilityLabel("Clip \(index + 1) sound")
        .accessibilityValue(spoken(clip, hasAudio: hasAudio))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badge(_ clip: TimelineClip, hasAudio: Bool) -> String {
        guard hasAudio else { return "MUTE" }
        switch clip.balance {
        case nil: return "ORIG"
        case .voiceOnly: return "VOX"
        case .removeVoice: return "−VOX"
        default: return "MIX"
        }
    }

    private func spoken(_ clip: TimelineClip, hasAudio: Bool) -> String {
        guard hasAudio else { return "No sound" }
        guard let balance = clip.balance else { return "Original" }
        func percent(_ v: Float) -> Int { Int((v * 100).rounded()) }
        return "Voice \(percent(balance.voice)) percent, everything else \(percent(balance.scene)) percent"
    }
}
