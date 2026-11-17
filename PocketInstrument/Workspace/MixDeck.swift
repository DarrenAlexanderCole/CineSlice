import EditCore
import SwiftUI

/// Mix state: line the reference music up with the sequence and balance it
/// against the clips' own sound. Everything here is in composition time.
/// Dragging the waveform slides the music; the clip band above it scrubs.
/// Each clip has its own level: pick one in the clip row and the CLIP fader follows it.
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
            MixClipPicker(model: model)
            HStack(spacing: 16) {
                Fader(
                    title: clipFaderTitle, value: model.selectedClip?.volume ?? 1,
                    onChange: { model.applyLevels(clip: $0) },
                    onCommit: { model.setClipVolume($0) }
                )
                .id(model.selectedClipID)  // a new clip starts a fresh drag, never inherits another's draft
                .disabled(model.selectedClip == nil)
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

    private var clipFaderTitle: String {
        guard let id = model.selectedClipID, let index = model.project.index(ofClip: id) else { return "CLIP" }
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
