import EditCore
import SwiftUI

/// The hardware tray that drops out beside Tools: a row of keys, scrolling sideways if it runs
/// out of room, and under it the panel of whichever adjusting tool is open. Only tools that work
/// are live. Scissor cuts the selected clip, stacked clip or sound at the playhead (for a clip,
/// the same split as upright Arrange; one undo step). Remove takes the selected sound or stacked
/// clip off its lane, or the selected clip out of the sequence. Volume sets the selected sound's,
/// clip's or song's level, and mutes a sound's lane; Fade sets how the selected sound, clip or
/// song fades in from and out to silence (a clip's sound only; the picture doesn't fade). Both are
/// heard live while a fader moves and make one undo step when it's let go. Trim cuts the selected clip, stacked clip or sound
/// back to the playhead from its start or its end; what's kept stays where it played, so a gap
/// opens and nothing else moves (one undo step).
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

        /// Opens a panel rather than acting at once.
        var adjusts: Bool { self == .trim || self == .volume || self == .fade }
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
                    case .trim: trimPanel
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

    /// Two keys that cut the selection back to the playhead: its start up to it, or its end from it.
    /// Each is lit only while the playhead is inside the selection with enough left to keep.
    private var trimPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                trimKey(.start, symbol: "arrow.right.to.line", title: "TRIM IN", label: "Trim start to playhead")
                trimKey(.end, symbol: "arrow.left.to.line", title: "TRIM OUT", label: "Trim end to playhead")
            }
            Text(
                model.canTrimSelection(.start) || model.canTrimSelection(.end)
                    ? "CUTS BACK TO THE PLAYHEAD" : "PUT THE PLAYHEAD INSIDE THE SELECTION"
            )
            .font(Theme.mono(7, weight: .bold))
            .foregroundStyle(Theme.ivory.opacity(0.6))
            .accessibilityHidden(true)
        }
    }

    private func trimKey(_ edge: TrimEdge, symbol: String, title: String, label: String) -> some View {
        let enabled = model.canTrimSelection(edge)
        return Button {
            model.trimSelection(edge)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                Text(title).font(Theme.mono(9, weight: .bold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.instrument(.key, active: enabled, height: 44))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityHint(enabled ? "" : "Put the playhead inside the selected clip or sound.")
    }

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
        } else if model.isMusicSelected, let music = model.project.referenceAudio {
            Fader(
                title: "SONG LEVEL", value: music.volume,
                onChange: { model.applyLevels(music: $0) },
                onCommit: { model.setMusicVolume($0) }
            )
            .accessibilityLabel("Song level")
        }
    }

    /// What Fade works on: its length, current fades, and how to hear and keep new ones.
    private struct FadeSubject {
        let length: MediaTime
        let fadeIn: MediaTime
        let fadeOut: MediaTime
        let hear: (MediaTime, MediaTime) -> Void
        let keep: (MediaTime, MediaTime) -> Void

        func preview(_ fades: (in: MediaTime, out: MediaTime)) { hear(fades.in, fades.out) }
        func commit(_ fades: (in: MediaTime, out: MediaTime)) { keep(fades.in, fades.out) }
    }

    /// The selected sound, clip of the sequence, or the song (where it's heard).
    private var fadeSubject: FadeSubject? {
        if let sound = model.selectedSound {
            return FadeSubject(
                length: sound.sourceRange.duration, fadeIn: sound.fadeIn, fadeOut: sound.fadeOut,
                hear: { fadeIn, fadeOut in
                    var heard = sound
                    heard.fadeIn = fadeIn
                    heard.fadeOut = fadeOut
                    model.applyLevels(sound: heard)
                },
                keep: { model.setSoundFades(in: $0, out: $1) })
        }
        if let clip = model.selectedClip {
            return FadeSubject(
                length: clip.compositionDuration, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut,
                hear: { model.applyLevels(clipFades: ($0, $1)) },
                keep: { model.setClipFades(in: $0, out: $1) })
        }
        if model.isMusicSelected, let music = model.project.referenceAudio {
            return FadeSubject(
                length: model.project.musicHeardRange(music).duration, fadeIn: music.fadeIn, fadeOut: music.fadeOut,
                hear: { model.applyLevels(musicFades: ($0, $1)) },
                keep: { model.setMusicFades(in: $0, out: $1) })
        }
        return nil
    }

    /// The fade in and fade out, each up to the whole length, the two together never longer
    /// than it (moving one cuts the other back).
    @ViewBuilder
    private var fadePanel: some View {
        if let subject = fadeSubject {
            let length = max(subject.length.seconds, 0.001)
            let seconds: (Float) -> String = { String(format: "%.1f s", Double($0) * length) }
            VStack(spacing: 8) {
                Fader(
                    title: "FADE IN", value: Float(subject.fadeIn.seconds / length), detents: [0],
                    display: seconds,
                    onChange: { subject.preview(faded(subject, in: $0, out: nil)) },
                    onCommit: { subject.commit(faded(subject, in: $0, out: nil)) }
                )
                .accessibilityLabel("Fade in")
                Fader(
                    title: "FADE OUT", value: Float(subject.fadeOut.seconds / length), detents: [0],
                    display: seconds,
                    onChange: { subject.preview(faded(subject, in: nil, out: $0)) },
                    onCommit: { subject.commit(faded(subject, in: nil, out: $0)) }
                )
                .accessibilityLabel("Fade out")
            }
        }
    }

    /// `subject`'s fades with a new fade in or out (as a fraction of its length), the other cut
    /// back if the two would overlap.
    private func faded(
        _ subject: FadeSubject, in fadeIn: Float?, out fadeOut: Float?
    ) -> (in: MediaTime, out: MediaTime) {
        let length = subject.length
        var result = (in: subject.fadeIn, out: subject.fadeOut)
        if let fadeIn {
            result.in = MediaTime(seconds: length.seconds * Double(fadeIn))
            result.out = min(result.out, length - result.in)
        }
        if let fadeOut {
            result.out = MediaTime(seconds: length.seconds * Double(fadeOut))
            result.in = min(result.in, length - result.out)
        }
        return result
    }

    // MARK: Keys

    /// Scissor needs the playhead inside the selected sound, or the selected clip (any clip when
    /// nothing is selected), away from its ends.
    private var canCut: Bool {
        if model.isMusicSelected { return false }
        if model.selectedLayerClipID != nil { return model.layerSplitTime != nil }
        if model.selectedSoundID != nil { return model.soundSplitTime != nil }
        guard let point = model.splitPoint else { return false }
        return model.selectedClipID == nil || model.selectedClipID == point.clipID
    }

    /// Something with sound selected: a sound, a clip of the sequence or the song (stacked clips
    /// are picture only).
    private var hasSound: Bool { model.selectedSoundID != nil || model.selectedClipID != nil || model.isMusicSelected }

    private func isEnabled(_ tool: Tool) -> Bool {
        switch tool {
        case .scissor: canCut
        // The song is changed or taken out upright, in Mix.
        case .remove: model.selectedSoundID != nil || model.selectedClipID != nil || model.selectedLayerClipID != nil
        case .volume, .fade: hasSound
        case .trim: model.trimTarget != nil
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
            case .trim, .volume, .fade:
                withAnimation(.easeInOut(duration: 0.2)) { panel = panel == tool ? nil : tool }
                Haptics.detent()
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.symbol).font(.system(size: 16, weight: .semibold))
                Text(tool.title.uppercased()).font(Theme.mono(8, weight: .bold))
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
        switch (tool, enabled) {
        case (.remove, true): return "Takes the selected clip or sound out."
        case (.remove, false), (.volume, false), (.trim, false): return "Select a clip or sound first."
        case (.trim, true): return "Cuts the selected clip or sound back to the playhead."
        case (.volume, true): return "Sets the level of the selected clip, sound or song."
        case (.fade, true): return "Sets how the selected clip, sound or song fades in and out."
        case (.fade, false): return "Select a clip, sound or song first."
        case (_, true): return ""
        default: return "Put the playhead inside the selected clip or sound, away from its ends."
        }
    }
}
