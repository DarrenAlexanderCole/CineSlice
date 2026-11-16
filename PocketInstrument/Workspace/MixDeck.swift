import EditCore
import SwiftUI

/// Mix state: line the reference music up with the sequence and balance it
/// against the clips' own sound. Everything here is in composition time.
struct MixDeck: View {
    var model: WorkspaceModel
    var onAddMusicFile: () -> Void
    var onAddMusicFromVideo: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            SequenceRuler(model: model)
            if let music = model.project.referenceAudio {
                MusicLane(model: model, music: music)
                alignmentRow(music)
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
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    /// Where the song sits relative to the video, with one-frame nudges.
    private func alignmentRow(_ music: AudioTrack) -> some View {
        let startsBefore = music.offset <= .zero
        return HStack(spacing: 8) {
            Button {
                model.nudgeMusic(frames: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.instrument())
            .accessibilityLabel("Move music one frame earlier")
            VStack(spacing: 2) {
                Text(startsBefore ? "SONG AT VIDEO START" : "SONG ENTERS AT VIDEO")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                TimecodeText(
                    time: startsBefore ? MediaTime.zero - music.offset : music.offset,
                    frameRate: Double(model.project.exportSettings.frameRate), size: 15, color: Theme.signal)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Button {
                model.nudgeMusic(frames: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.instrument())
            .accessibilityLabel("Move music one frame later")
        }
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

/// The song's waveform laid under the sequence. Drag it sideways to slide the
/// music earlier or later; the dimmed band marks where music is heard.
struct MusicLane: View {
    var model: WorkspaceModel
    let music: AudioTrack

    private let height: CGFloat = 56
    @State private var draftOffset: MediaTime?
    @State private var baseOffset: MediaTime = .zero

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let offset = draftOffset ?? music.offset
            let duration = model.project.duration
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.obsidian)
                if let placement = MusicPlacement(
                    track: AudioTrack(fileName: music.fileName, duration: music.duration, offset: offset),
                    sequenceDuration: duration)
                {
                    let x0 = x(for: placement.compositionRange.start, width)
                    let x1 = x(for: placement.compositionRange.end, width)
                    Rectangle().fill(Theme.olive.opacity(0.25))
                        .frame(width: max(1, x1 - x0), height: height)
                        .offset(x: x0)
                }
                if let waveform = model.waveform {
                    bars(waveform, offset: offset, width: width)
                } else if model.musicURL == nil {
                    status("Music file is missing")
                } else {
                    status("Reading waveform…")
                }
                Rectangle().fill(Theme.ivory)
                    .frame(width: 2, height: height)
                    .offset(x: x(for: model.currentTime, width) - 1)
                Text(music.originalFilename ?? "Music")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(draftOffset == nil ? Theme.hairline : Theme.signal)
            )
            .contentShape(Rectangle())
            .gesture(slideGesture(width: width))
        }
        .frame(height: height)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Music position")
        .accessibilityValue(
            String(
                format: "Song starts %.2f seconds %@ the video", abs(music.offset.seconds),
                music.offset <= .zero ? "before" : "into")
        )
        .accessibilityAdjustableAction { direction in
            model.setMusicOffset(music.offset + MediaTime(seconds: direction == .increment ? 1 : -1))
        }
    }

    private func x(for t: MediaTime, _ width: CGFloat) -> CGFloat {
        let d = model.project.duration.seconds
        guard d > 0 else { return 0 }
        return CGFloat(min(max(t.seconds / d, 0), 1)) * width
    }

    private func bars(_ waveform: Waveform, offset: MediaTime, width: CGFloat) -> some View {
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let count = max(1, Int(width / (barWidth + gap)))
        // The lane spans composition 0…duration, i.e. audio −offset…duration−offset.
        let levels = waveform.envelope(
            from: MediaTime.zero - offset, to: model.project.duration - offset, buckets: count)
        return Canvas { context, size in
            let mid = size.height / 2
            for (i, level) in levels.enumerated() where level > 0 {
                let h = max(1, CGFloat(level) * (size.height - 8))
                let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: mid - h / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.signal.opacity(0.85)))
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.secondaryLabel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func slideGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                if draftOffset == nil {
                    baseOffset = music.offset
                    Haptics.press()
                }
                let seconds = Double(g.translation.width / max(width, 1)) * model.project.duration.seconds
                // Snap to the export frame grid.
                let fps = model.sequenceFrame.timescale
                let proposed = MediaTime(
                    value: Int64(((baseOffset.seconds + seconds) * Double(fps)).rounded()), timescale: fps)
                draftOffset = music.clampedOffset(proposed, sequenceDuration: model.project.duration)
            }
            .onEnded { _ in
                if let final = draftOffset { model.setMusicOffset(final) }
                draftOffset = nil
                Haptics.detent()
            }
    }
}
