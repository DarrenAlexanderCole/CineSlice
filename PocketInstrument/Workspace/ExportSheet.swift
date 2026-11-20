import EditCore
import SwiftUI
import UIKit

/// Release: H.264 at the sequence's frame (a vertical one can be cut to the feed's 4:5), a sound
/// policy (including silent for Instagram music), the Instagram handoff (where to start the song),
/// progress + cancel, then Save to Photos / Open Instagram / Share. It rises over the deck as
/// more of the instrument: an aluminum title plate, engraved sections in recessed wells, choices
/// as keys that light, and a segment meter while it renders.
struct ExportSheet: View {
    var model: WorkspaceModel

    private enum Phase: Equatable {
        case ready
        case exporting(Double)
        case done(ExportResult)
        case failed(String)
    }

    @State private var phase: Phase = .ready
    @State private var exportTask: Task<Void, Never>?
    @State private var savedToPhotos = false
    @State private var saveError: String?
    @State private var copiedSync = false
    /// The saved video's Photos identifier, to open Instagram on it.
    @State private var photosIdentifier: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let settings = model.project.exportSettings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                details(settings)
                if !settings.isLandscape { framePicker(settings) }
                soundPicker()
                if let note = MusicSyncNote(project: model.project) {
                    handoff(note)
                }
                PanelSection(title: "Output") { content }
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationBackground { Chassis(cornerRadius: 0) }
        .presentationCornerRadius(26)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isExporting)
        .onDisappear { exportTask?.cancel() }
    }

    @ViewBuilder
    private func details(_ settings: ExportSettings) -> some View {
        TitlePlate(title: "Release", subtitle: "H.264 MP4 · \(settings.frameRate) fps")
        HStack(spacing: 0) {
            readout("Duration", String(format: "%.2fs", model.project.duration.seconds))
            readout("Frame", "\(settings.outputAspectLabel) · \(settings.outputWidth)×\(settings.outputHeight)")
            readout("Clips", "\(model.project.clips.count)")
        }
        .padding(.vertical, 10)
        .recessed(cornerRadius: 14)

    }

    // MARK: Frame

    /// Full 9:16 for Reels and Stories, or the centre 4:5 the feed shows (the dashed lines in the viewer).
    private func framePicker(_ settings: ExportSettings) -> some View {
        PanelSection(title: "Frame") {
            option(
                "Reels · Stories  9:16", "The whole vertical frame.", isOn: !settings.cutsToFeed
            ) { model.setFeedCut(false) }
            option(
                "Feed  4:5", "The centre of the frame, between the viewer's dashed lines. 1080×1350.",
                isOn: settings.cutsToFeed
            ) { model.setFeedCut(true) }
        }
        .disabled(isExporting)
    }

    /// One choice of several, as a key that lights when chosen: a title and a line of detail.
    private func option(_ title: String, _ detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.detent()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.signal : Theme.label)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(OptionKeyStyle(isOn: isOn))
    }

    /// A small engraved label over a monospaced value.
    private func readout(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title.uppercased()).font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
            Text(value).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.label).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sound

    private var policies: [SoundPolicy] {
        model.project.referenceAudio == nil ? [.clipsOnly, .silent] : [.silent, .clipsOnly, .clipsAndMusic]
    }

    private func soundPicker() -> some View {
        let current = model.project.exportSoundPolicy
        return PanelSection(title: "Sound") {
            ForEach(policies, id: \.self) { policy in
                option(title(policy), detail(policy), isOn: current == policy) { model.setSoundPolicy(policy) }
            }
        }
        .disabled(isExporting)
    }

    private func title(_ policy: SoundPolicy) -> String {
        switch policy {
        case .silent: return "Silent"
        case .clipsOnly: return "Clip audio only"
        case .clipsAndMusic: return "Clip + music"
        }
    }

    private func detail(_ policy: SoundPolicy) -> String {
        switch policy {
        case .silent: return "No sound. Add the licensed song inside Instagram afterwards."
        case .clipsOnly: return "The original sound from your clips. Your music is left out."
        case .clipsAndMusic:
            return "Exactly what you hear in the preview. For private drafts, not for Instagram upload."
        }
    }

    // MARK: Instagram handoff

    /// Where the song starts, big, and how to line the same song up in Instagram by hand: apps
    /// can't attach Instagram's licensed music or set its start.
    private func handoff(_ note: MusicSyncNote) -> some View {
        let start = MusicSyncNote.clock(note.songStartSeconds)
        let song = note.songTitle.map { title in
            note.songArtist.map { "\u{201C}\(title)\u{201D} by \($0)" } ?? "\u{201C}\(title)\u{201D}"
        }
        let songName =
            song ?? (note.referenceKind == "quickClick" ? "your song" : "\u{201C}\(note.referenceFilename)\u{201D}")
        // What the big readout shows: where the song starts, or for a guide without a song
        // position, the moment in the video to line the song up with.
        let cue: (label: String, seconds: Double, step: String) =
            if let downbeat = note.firstDownbeatSeconds {
                (
                    "FIRST DOWNBEAT AT", downbeat,
                    "Start the song on a downbeat so it lands \(MusicSyncNote.clock(downbeat)) in."
                )
            } else if let spot = note.tappedSpotSeconds {
                (
                    "TAPPED SPOT AT", spot,
                    "Start it so the spot you tapped from\(note.songSection.map { " (\($0))" } ?? "") comes in at \(MusicSyncNote.clock(spot))."
                )
            } else {
                ("SONG STARTS AT", note.songStartSeconds, "Drag the song so it starts at \(start).")
            }
        return PanelSection(title: "Instagram handoff") {
            HStack(alignment: .firstTextBaseline) {
                Text(cue.label).font(Theme.mono(10, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
                Spacer()
                Text(MusicSyncNote.clock(cue.seconds))
                    .font(Theme.mono(30, weight: .bold))
                    .foregroundStyle(Theme.signal)
                    .shadow(color: Theme.signal.opacity(0.5), radius: 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                // A lit display window inside the well.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.signal.opacity(0.2), lineWidth: 1))
            )
            .accessibilityElement(children: .combine)
            if model.project.exportSoundPolicy == .silent {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Render, then save the silent video to Photos.")
                    step(2, "In Instagram, make a Reel with it and add \(songName).")
                    step(3, cue.step)
                }
            } else {
                Text(note.instruction).font(.system(size: 13)).foregroundStyle(Theme.label)
            }
            Text(note.caveat)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryLabel)
            Button(copiedSync ? "Copied" : "Copy song start") {
                UIPasteboard.general.string = note.instruction
                copiedSync = true
                Haptics.success()
            }
            .buttonStyle(.instrument(height: 34))
            .accessibilityLabel("Copy sync instruction")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(Theme.mono(11, weight: .bold)).foregroundStyle(Theme.signal)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.label)
        }
    }

    private var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            Button {
                start()
            } label: {
                Label("Render video", systemImage: "record.circle")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.instrument(.prominent, height: 52))
            // Until then, clips set to voice only or reduced voice would render as recorded.
            .disabled(model.isProcessingVoice && model.project.exportSoundPolicy.includesClipAudio)
            if model.isProcessingVoice && model.project.exportSoundPolicy.includesClipAudio {
                Text("Processing clip sound… Render is ready when it finishes.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }

        case .exporting(let p):
            VStack(alignment: .leading, spacing: 10) {
                SegmentMeter(value: p)
                HStack {
                    LED(isOn: true)
                    Text("RENDERING \(Int(p * 100))%").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.signal)
                    Spacer()
                    Button("Cancel") { exportTask?.cancel() }.buttonStyle(.instrument(height: 34))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rendering \(Int(p * 100)) percent")

        case .done(let result):
            let url = result.videoURL
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    LED(isOn: true)
                    Text(model.project.exportSoundPolicy == .silent ? "Rendered (silent)" : "Rendered")
                        .font(Theme.mono(13, weight: .bold))
                        .foregroundStyle(Theme.signal)
                }
                SegmentMeter(value: 1)
                HStack(spacing: 10) {
                    Button(savedToPhotos ? "Saved to Photos" : "Save to Photos") {
                        Task {
                            do {
                                photosIdentifier = try await ExportService.saveToPhotos(url)
                                savedToPhotos = true
                                Haptics.success()
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.instrument(.key))
                    .disabled(savedToPhotos)
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.instrument())
                    Button("Again") {
                        phase = .ready
                        savedToPhotos = false
                        photosIdentifier = nil
                    }
                    .buttonStyle(.instrument())
                }
                // Once it's in Photos, Instagram can open on it (shown only when Instagram is installed).
                if savedToPhotos, let instagram = ExportService.instagramURL(forPhotosAsset: photosIdentifier) {
                    Button {
                        openURL(instagram)
                    } label: {
                        Label("Open Instagram", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.instrument(.prominent))
                    .accessibilityHint("Opens Instagram on the video you just saved, to add the song.")
                }
                if let noteURL = result.syncNoteURL {
                    ShareLink(item: noteURL) { Label("Share sync file (.json)", systemImage: "doc.text") }
                        .buttonStyle(.instrument())
                }
                if let saveError {
                    Text(saveError).font(.system(size: 12)).foregroundStyle(Theme.aluminum)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.aluminum)
                Button("Try again") { start() }.buttonStyle(.instrument(.key))
            }
        }
    }

    private func start() {
        model.saveNow()
        let project = model.project
        let store = model.store
        phase = .exporting(0)
        exportTask = Task {
            do {
                let result = try await ExportService.export(project: project, store: store) { p in
                    if case .exporting = phase { phase = .exporting(p) }
                }
                phase = .done(result)
                Haptics.success()
            } catch is CancellationError {
                phase = .ready
            } catch ExportError.cancelled {
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
                Haptics.warning()
            }
        }
    }
}
