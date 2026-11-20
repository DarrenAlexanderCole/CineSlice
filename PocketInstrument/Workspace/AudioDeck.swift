import EditCore
import SwiftUI

/// Audio state: each clip's own sound, cleaned up on the device. Pick a clip in the row, then
/// play it as recorded, voice only (background noise taken out), or with the voices reduced (for
/// someone talking behind the camera). Processing runs once per source in the background and the
/// clip plays as recorded until it's ready; the choice is one undo step and never touches the
/// footage. Play and loop to audition it in the sequence.
struct AudioDeck: View {
    var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 10) {
            AudioClipPicker(model: model)
            SequenceLane(model: model)
            treatmentPanel
            TransportRow(model: model, compact: true) {
                EmptyView()
            } trailing: {
                LoopButton(model: model)
            }
        }
    }

    @ViewBuilder
    private var treatmentPanel: some View {
        if let clip = model.selectedClip, let source = model.project.source(for: clip) {
            let number = (model.project.index(ofClip: clip.id) ?? 0) + 1
            PanelSection(title: String(format: "Clip %02d sound", number)) {
                if source.hasAudio {
                    HStack(spacing: 6) {
                        option("Original", "As recorded", nil, clip)
                        option("Voice only", "Noise out", .voiceOnly, clip)
                        option("Reduce voice", "Scene kept", .reduceVoice, clip)
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
        _ title: String, _ detail: String, _ treatment: VoiceTreatment?, _ clip: TimelineClip
    ) -> some View {
        let isOn = clip.voice == treatment
        return Button {
            model.setVoiceTreatment(treatment)
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
        .accessibilityHint(hint(treatment))
    }

    private func hint(_ treatment: VoiceTreatment?) -> String {
        switch treatment {
        case nil: return "Plays the clip's sound as recorded."
        case .voiceOnly: return "Keeps the voices and takes out background noise."
        case .reduceVoice: return "Turns voices down and keeps the rest of the scene."
        }
    }

    /// Processing progress, or what the chosen treatment can and can't do.
    @ViewBuilder
    private func status(_ clip: TimelineClip, _ source: SourceAsset) -> some View {
        if let progress = model.voiceProgress[source.id], clip.voice != nil {
            HStack(spacing: 8) {
                LED(isOn: true)
                Text("PROCESSING \(Int(progress * 100))%")
                    .font(Theme.mono(11, weight: .bold))
                    .foregroundStyle(Theme.signal)
                Spacer(minLength: 0)
                Text("Plays as recorded until done")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .accessibilityElement(children: .combine)
        } else if clip.voice == .reduceVoice {
            Text("Voices are lowered, not removed: some may still be heard.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
        } else {
            Text("Processed on this iPhone. Your footage isn't changed.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
        }
    }
}

/// A compact option key for a row of three: centred, lit when chosen.
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
                        .foregroundStyle(clip.voice != nil ? Theme.signal : Theme.secondaryLabel)
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
        switch clip.voice {
        case nil: return "ORIG"
        case .voiceOnly: return "VOX"
        case .reduceVoice: return "−VOX"
        }
    }

    private func spoken(_ clip: TimelineClip, hasAudio: Bool) -> String {
        guard hasAudio else { return "No sound" }
        switch clip.voice {
        case nil: return "Original"
        case .voiceOnly: return "Voice only"
        case .reduceVoice: return "Voice reduced"
        }
    }
}
