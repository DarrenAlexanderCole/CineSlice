import EditCore
import SwiftUI

/// Mix state: line the reference music up with the sequence and balance it
/// against the clips' own sound. Everything here is in composition time.
/// Dragging the waveform slides the music; the clip band above it scrubs.
struct MixDeck: View {
    var model: WorkspaceModel
    var onAddMusicFile: () -> Void
    var onAddMusicFromVideo: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            SequenceLane(model: model, waveformDrag: .slideMusic)
            if let music = model.project.referenceAudio {
                alignment(music)
            } else {
                emptyMusic
            }
            HStack(spacing: 16) {
                Fader(
                    title: "CLIPS", value: model.project.clipAudioVolume,
                    onChange: { model.applyLevels(clip: $0) },
                    onCommit: { model.setClipVolume($0) })
                Fader(
                    title: "MUSIC", value: model.project.referenceAudio?.volume ?? 1,
                    onChange: { model.applyLevels(music: $0) },
                    onCommit: { model.setMusicVolume($0) }
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

    /// Where the song sits relative to the video, with frame and 10 ms nudges.
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
                nudge("+10MS", by: fine, label: "Music 10 milliseconds later")
                nudge("+1F", by: frame, label: "Music one frame later")
            }
        }
        .padding(.horizontal, 8)
    }

    private func nudge(_ title: String, by step: MediaTime, label: String) -> some View {
        Button(title) { model.nudgeMusic(by: step) }
            .buttonStyle(.instrument())
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
