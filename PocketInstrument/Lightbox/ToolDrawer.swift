import EditCore
import SwiftUI

/// The hardware tray that drops out beside Tools: a row of keys, scrolling sideways if it runs
/// out of room, and under it the panel of whichever adjusting tool is open. Only tools that work
/// are live. Scissor cuts the selected clip, stacked clip or sound at the playhead (for a clip,
/// the same split as upright Arrange; one undo step). Remove takes the selected sound or stacked
/// clip off its lane, or the selected clip out of the sequence. Volume sets the selected sound's or clip's level, and mutes
/// a sound's lane; Fade sets a sound's fade in and out. Both are heard live while a fader moves
/// and make one undo step when it's let go. Trim is shown dark and can't be pressed until it's
/// built, so the tray's order is visible without dead buttons.
struct ToolDrawer: View {
    var model: WorkspaceModel

    /// The adjusting tool whose panel is open.
    @State private var panel: Tool?

    private enum Tool: CaseIterable {
        case scissor, remove, trim, volume, fade

        var title: String {
            switch self {
            case .scissor: "Scissor"
            case .remove: "Remove"
            case .trim: "Trim"
            case .volume: "Volume"
            case .fade: "Fade"
            }
        }

        var symbol: String {
            switch self {
            case .scissor: "scissors"
            case .remove: "trash"
            case .trim: "arrow.left.and.right.square"
            case .volume: "speaker.wave.2"
            case .fade: "chart.line.uptrend.xyaxis"
            }
        }

        var isBuilt: Bool { self != .trim }
        /// Opens a panel rather than acting at once.
        var adjusts: Bool { self == .volume || self == .fade }
    }

    private static let keyWidth: CGFloat = 62
    private static let rowWidth = keyWidth * CGFloat(Tool.allCases.count) + 4 * CGFloat(Tool.allCases.count - 1)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        key(tool)
                    }
                }
                .padding(6)
            }
            .fixedSize(horizontal: true, vertical: false)
            if let open = panel, isEnabled(open) {
                Group {
                    switch open {
                    case .volume: volumePanel
                    case .fade: fadePanel
                    default: EmptyView()
                    }
                }
                .padding(10)
                .frame(width: Self.rowWidth)
                .recessed(cornerRadius: 8)
                .padding([.horizontal, .bottom], 6)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.ivory, Theme.aluminum, Color(hex: 0xA2A498)], startPoint: .top,
                        endPoint: .bottom)
                )
                .overlay(
                    BrushedMetal(strength: 1.2).clipShape(RoundedRectangle(cornerRadius: 12)).blendMode(.multiply)
                )
                .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    // MARK: Panels

    /// The selected sound's level and its lane's mute, or the selected clip's level.
    @ViewBuilder
    private var volumePanel: some View {
        if let sound = model.selectedSound {
            HStack(alignment: .bottom, spacing: 10) {
                Fader(
                    title: "SOUND LEVEL", value: sound.volume,
                    onChange: { level in
                        var heard = sound
                        heard.volume = level
                        model.applyLevels(sound: heard)
                    },
                    onCommit: { model.setSoundLevel($0) }
                )
                .accessibilityLabel("Sound level")
                if let lane = model.project.soundTracks.first(where: { $0.clips.contains { $0.id == sound.id } }) {
                    Button {
                        model.toggleMute(soundTrack: lane.id)
                    } label: {
                        Image(systemName: lane.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 22)
                    }
                    .buttonStyle(.instrument(.key, active: lane.isMuted, height: 34))
                    .accessibilityLabel("Mute lane")
                    .accessibilityValue(lane.isMuted ? "Muted" : "Playing")
                }
            }
        } else if let clip = model.selectedClip {
            Fader(
                title: "CLIP LEVEL", value: clip.volume,
                onChange: { model.applyLevels(clip: $0) },
                onCommit: { model.setClipVolume($0) }
            )
            .accessibilityLabel("Clip level")
        }
    }

    /// The selected sound's fade in and fade out, each up to the whole sound, the two together
    /// never longer than it.
    @ViewBuilder
    private var fadePanel: some View {
        if let sound = model.selectedSound {
            let length = max(sound.sourceRange.duration.seconds, 0.001)
            let seconds: (Float) -> String = { String(format: "%.1f s", Double($0) * length) }
            VStack(spacing: 8) {
                Fader(
                    title: "FADE IN", value: Float(sound.fadeIn.seconds / length), detents: [0],
                    display: seconds,
                    onChange: { model.applyLevels(sound: faded(sound, in: $0, out: nil)) },
                    onCommit: { commitFades(faded(sound, in: $0, out: nil)) }
                )
                .accessibilityLabel("Fade in")
                Fader(
                    title: "FADE OUT", value: Float(sound.fadeOut.seconds / length), detents: [0],
                    display: seconds,
                    onChange: { model.applyLevels(sound: faded(sound, in: nil, out: $0)) },
                    onCommit: { commitFades(faded(sound, in: nil, out: $0)) }
                )
                .accessibilityLabel("Fade out")
            }
        }
    }

    /// `sound` with a new fade in or out (as a fraction of its length), the other cut back if the
    /// two would overlap.
    private func faded(_ sound: SoundClip, in fadeIn: Float?, out fadeOut: Float?) -> SoundClip {
        let length = sound.sourceRange.duration
        var heard = sound
        if let fadeIn {
            heard.fadeIn = MediaTime(seconds: length.seconds * Double(fadeIn))
            heard.fadeOut = min(heard.fadeOut, length - heard.fadeIn)
        }
        if let fadeOut {
            heard.fadeOut = MediaTime(seconds: length.seconds * Double(fadeOut))
            heard.fadeIn = min(heard.fadeIn, length - heard.fadeOut)
        }
        return heard
    }

    private func commitFades(_ sound: SoundClip) {
        model.setSoundFades(in: sound.fadeIn, out: sound.fadeOut)
    }

    // MARK: Keys

    /// Scissor needs the playhead inside the selected sound, or the selected clip (any clip when
    /// nothing is selected), away from its ends.
    private var canCut: Bool {
        if model.selectedLayerClipID != nil { return model.layerSplitTime != nil }
        if model.selectedSoundID != nil { return model.soundSplitTime != nil }
        guard let point = model.splitPoint else { return false }
        return model.selectedClipID == nil || model.selectedClipID == point.clipID
    }

    /// Something with sound selected: a sound or a clip of the sequence (stacked clips are picture only).
    private var hasSelection: Bool { model.selectedSoundID != nil || model.selectedClipID != nil }

    private func isEnabled(_ tool: Tool) -> Bool {
        switch tool {
        case .scissor: canCut
        case .remove: hasSelection || model.selectedLayerClipID != nil
        case .volume: hasSelection
        case .fade: model.selectedSoundID != nil
        case .trim: false
        }
    }

    private func key(_ tool: Tool) -> some View {
        let enabled = isEnabled(tool)
        let lit = (tool == .scissor && enabled) || (panel == tool && enabled)
        return Button {
            switch tool {
            case .scissor:
                if model.selectedLayerClipID != nil {
                    model.splitSelectedLayerClip()
                } else if model.selectedSoundID != nil {
                    model.splitSelectedSound()
                } else {
                    model.splitAtPlayhead()
                }
            case .remove: model.removeSelection()
            case .volume, .fade:
                withAnimation(.easeInOut(duration: 0.2)) { panel = panel == tool ? nil : tool }
                Haptics.detent()
            case .trim: break
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.symbol).font(.system(size: 16, weight: .semibold))
                Text(tool.title.uppercased()).font(Theme.mono(8, weight: .bold))
                if !tool.isBuilt {
                    Text("SOON").font(Theme.mono(6, weight: .heavy)).opacity(0.7)
                }
            }
            .foregroundStyle(Color(hex: 0x2B2F27))
            .frame(width: Self.keyWidth, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(lit ? Theme.signal : Color.white.opacity(0.18))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(tool == .scissor ? "Scissor: cut at playhead" : tool.title)
        .accessibilityValue(tool.adjusts && enabled ? (panel == tool ? "Open" : "Closed") : "")
        .accessibilityHint(hint(tool, enabled: enabled))
    }

    private func hint(_ tool: Tool, enabled: Bool) -> String {
        guard tool.isBuilt else { return "Not available yet." }
        switch (tool, enabled) {
        case (.remove, true): return "Takes the selected clip or sound out."
        case (.remove, false), (.volume, false): return "Select a clip or sound first."
        case (.volume, true): return "Sets the level of the selected clip or sound."
        case (.fade, true): return "Sets how the selected sound fades in and out."
        case (.fade, false): return "Select a sound first."
        case (_, true): return ""
        default: return "Put the playhead inside the selected clip or sound, away from its ends."
        }
    }
}
