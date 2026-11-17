import EditCore
import SwiftUI

/// Mix state: line the reference music up with the sequence and balance it
/// against the clips' own sound. Everything here is in composition time.
/// Dragging the waveform slides the music; the clip band above it scrubs. Once lined up, the
/// lock keeps the song in place: the waveform then scrubs too, and the nudges are off.
/// Each clip has its own level: pick one in the clip row and the CLIP fader follows it.
/// With Write on, riding a fader during playback records it as a curve (drawn in the lane);
/// inside a recorded pass the fader follows the curve and reads AUTO, and with Write off, moving
/// it there raises or lowers that whole pass (shape kept). A CLIP ride writes onto
/// each clip it plays over, and the fader names the clip under the playhead while it records.
struct MixDeck: View {
    var model: WorkspaceModel
    var onAddMusicFile: () -> Void
    var onAddMusicFromVideo: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            SequenceLane(model: model, waveformDrag: .slideMusic, showsAutomation: true)
            if let music = model.project.referenceAudio {
                alignment(music)
            } else {
                emptyMusic
            }
            MixClipPicker(model: model)
            HStack(spacing: 10) {
                WriteKey(model: model)
                ClearKey(model: model)
                Fader(
                    title: faderTitle(clipFaderTitle, .clipAudio), value: model.faderLevel(.clipAudio),
                    onChange: { model.faderMoved(.clipAudio, to: $0) },
                    onRelease: { model.faderReleased(.clipAudio, at: $0) },
                    onCommit: { model.faderSet(.clipAudio, to: $0) }
                )
                .id(model.selectedClipID)  // a new clip starts a fresh drag, never inherits another's draft
                .disabled(model.selectedClip == nil)
                Fader(
                    title: faderTitle("MUSIC", .music), value: model.faderLevel(.music),
                    onChange: { model.faderMoved(.music, to: $0) },
                    onRelease: { model.faderReleased(.music, at: $0) },
                    onCommit: { model.faderSet(.music, to: $0) }
                )
                .disabled(model.project.referenceAudio == nil)
            }
            TransportRow(model: model) {
                musicMenu
            } trailing: {
                LoopButton(model: model)
            }
        }
    }

    private func faderTitle(_ title: String, _ target: AutomationTarget) -> String {
        model.isAutomated(target) ? "\(title) · AUTO" : title
    }

    private var clipFaderTitle: String {
        guard let id = model.recordingClipID ?? model.selectedClipID, let index = model.project.index(ofClip: id)
        else { return "CLIP" }
        return String(format: "CLIP %02d", index + 1)
    }

    private var emptyMusic: some View {
        VStack(spacing: 8) {
            Text("Add a song to line up with your footage")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            HStack(spacing: 10) {
                Button("Files", action: onAddMusicFile).buttonStyle(.instrument(.key))
                Button("From a video", action: onAddMusicFromVideo).buttonStyle(.instrument())
                Button("Click") { Task { await model.addDemoClickTrack() } }
                    .buttonStyle(.instrument())
                    .accessibilityLabel("Demo click track")
                    .accessibilityHint("Generates a 30 second, 120 BPM metronome for testing sync")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    /// Where the song sits relative to the video, with frame and 10 ms nudges, and the lock
    /// that keeps it there once lined up.
    private func alignment(_ music: AudioTrack) -> some View {
        let startsBefore = music.offset <= .zero
        let frame = model.sequenceFrame
        let fine = WorkspaceModel.tenMilliseconds
        return VStack(spacing: 6) {
            HStack {
                Text(startsBefore ? "SONG AT VIDEO START" : "SONG ENTERS AT")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                Spacer()
                if music.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.signal)
                        .accessibilityLabel("Locked")
                }
                Text(MusicSyncNote.clock(abs(music.offset.seconds)))
                    .font(Theme.mono(15))
                    .monospacedDigit()
                    .foregroundStyle(Theme.signal)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) {
                nudge("−1F", by: MediaTime.zero - frame, label: "Music one frame earlier")
                nudge("−10MS", by: MediaTime.zero - fine, label: "Music 10 milliseconds earlier")
                Spacer(minLength: 0)
                Button {
                    model.toggleMusicLock()
                } label: {
                    Image(systemName: music.isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.instrument(active: music.isLocked))
                .accessibilityLabel("Lock music")
                .accessibilityValue(music.isLocked ? "Locked" : "Unlocked")
                .accessibilityHint("Keeps the song lined up: no sliding or nudging until unlocked.")
                Spacer(minLength: 0)
                nudge("+10MS", by: fine, label: "Music 10 milliseconds later")
                nudge("+1F", by: frame, label: "Music one frame later")
            }
        }
        .padding(.horizontal, 8)
    }

    private func nudge(_ title: String, by step: MediaTime, label: String) -> some View {
        Button(title) { model.nudgeMusic(by: step) }
            .buttonStyle(.instrument())
            .disabled(model.isMusicLocked)
            .accessibilityLabel(label)
    }

    private var musicMenu: some View {
        Menu {
            Button(action: onAddMusicFile) {
                Label(
                    model.project.referenceAudio == nil ? "Song from Files" : "Replace from Files",
                    systemImage: "folder")
            }
            Button(action: onAddMusicFromVideo) {
                Label("Sound from a video", systemImage: "film")
            }
            Button {
                Task { await model.addDemoClickTrack() }
            } label: {
                Label("Demo click track", systemImage: "metronome")
            }
            if model.project.referenceAudio != nil {
                Button(role: .destructive) {
                    model.removeMusic()
                } label: {
                    Label("Remove music", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ivory)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.instrument, Theme.obsidian], startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.hairline))
        }
        .accessibilityLabel("Music")
    }
}

/// Arms recording: while on, touching a fader during playback records it.
private struct WriteKey: View {
    var model: WorkspaceModel

    var body: some View {
        let isOn = model.isWriting
        let isRecording = model.recording != nil
        Button {
            model.isWriting.toggle()
            Haptics.tap()
        } label: {
            KeyFace(systemImage: isRecording ? "record.circle.fill" : "record.circle", isLit: isOn)
                .shadow(color: isOn ? Theme.signal.opacity(isRecording ? 0.9 : 0.5) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write automation")
        .accessibilityValue(isRecording ? "Recording" : isOn ? "On" : "Off")
        .accessibilityHint("When on, moving a fader during playback records it.")
    }
}

/// Clears recorded curves: the selected clip's, every clip's, or the music's. Each is one undo step.
private struct ClearKey: View {
    var model: WorkspaceModel

    var body: some View {
        let selected = model.selectedClip
        let clipCurves = !model.project.lane(for: .clipAudio).isEmpty
        let musicCurve = !model.project.automation.music.isEmpty
        Menu {
            Button(role: .destructive) {
                model.clearAutomation(.clipAudio, clipID: selected?.id)
            } label: {
                Label(selectedClipCurveTitle, systemImage: "film")
            }
            .disabled(selected?.levelCurve.isEmpty ?? true)
            Button(role: .destructive) {
                model.clearAutomation(.clipAudio)
            } label: {
                Label("Clear all clip curves", systemImage: "film.stack")
            }
            .disabled(!clipCurves)
            Button(role: .destructive) {
                model.clearAutomation(.music)
            } label: {
                Label("Clear music curve", systemImage: "music.note")
            }
            .disabled(!musicCurve)
        } label: {
            KeyFace(systemImage: "eraser", isLit: false)
        }
        .disabled(!clipCurves && !musicCurve)
        .opacity(clipCurves || musicCurve ? 1 : 0.4)
        .accessibilityLabel("Clear automation")
    }

    private var selectedClipCurveTitle: String {
        guard let id = model.selectedClipID, let index = model.project.index(ofClip: id) else {
            return "Clear clip curve"
        }
        return String(format: "Clear clip %02d curve", index + 1)
    }
}

/// A square dark key with an icon, lit in Signal when on.
private struct KeyFace: View {
    var systemImage: String
    var isLit: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isLit ? Theme.signal : Theme.ivory)
            .frame(width: Theme.minTouch, height: Theme.minTouch)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.instrument, Theme.obsidian], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isLit ? Theme.signal : Theme.hairline, lineWidth: isLit ? 1.5 : 1)
            )
    }
}

/// Small tiles for choosing which clip the CLIP fader sets. Each shows its level as a meter.
private struct MixClipPicker: View {
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
                    levelMeter(clip.volume, lit: isSelected)
                }
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
        .accessibilityLabel("Clip \(index + 1) level")
        .accessibilityValue("\(Int((clip.volume * 100).rounded())) percent")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func levelMeter(_ volume: Float, lit: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.instrument)
            Capsule().fill(lit ? Theme.signal : Theme.aluminum.opacity(0.6))
                .frame(width: 28 * CGFloat(volume))
        }
        .frame(width: 28, height: 4)
    }
}
