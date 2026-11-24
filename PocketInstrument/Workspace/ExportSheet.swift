import EditCore
import SwiftUI
import UIKit

/// Release: presets (1080p / 4K, 9:16 / 16:9), the sequence's frame (a vertical one can be cut to
/// the feed's 4:5), picture settings on faders and keys (resolution, frame rate, codec, bitrate,
/// keyframes) with a guide to what they'll give, a sound policy (including silent for Instagram
/// music) and its bitrate, the Instagram handoff (where to start the song), progress + cancel,
/// then Save to Photos / Open Instagram / Share. It rises over the deck as
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
    /// The settings while a fader is held, so the readouts and guide follow it; committed on release.
    @State private var draft: ExportSettings?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let settings = draft ?? model.project.exportSettings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                details(settings)
                presets(settings)
                if !settings.isLandscape { framePicker(settings) }
                picture(settings)
                guide(settings)
                soundPicker(settings)
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
        TitlePlate(title: "Release", subtitle: "\(codecName(settings.codec)) MP4 · \(settings.frameRate) fps")
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

    // MARK: Presets

    /// One tap to a common shape and size; the faders below fine-tune from there.
    private func presets(_ settings: ExportSettings) -> some View {
        PanelSection(title: "Presets") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ExportPreset.all) { preset in
                    option(preset.name, preset.detail, isOn: preset.matches(settings)) {
                        model.setExportSettings(preset.applied(to: model.project.exportSettings))
                    }
                    .accessibilityHint(
                        preset.landscape != settings.isLandscape
                            ? "Also turns the picture \(preset.landscape ? "horizontal" : "vertical")." : "")
                }
            }
        }
        .disabled(isExporting)
    }

    // MARK: Picture

    /// A fader position (0…1) and the value it stands for.
    struct Scale<Value> {
        let position: (Value) -> Float
        let value: (Float) -> Value
    }

    /// 480…2160 px on the short side, snapping to the standard sizes near them.
    static let resolutionScale = Scale<Int>(
        position: { Float($0 - 480) / 1680 },
        value: { p in
            let raw = 480 + Int((Float(1680) * p).rounded())
            if let standard = standardResolutions.first(where: { abs($0 - raw) <= 30 }) { return standard }
            return (raw / 8) * 8
        })
    static let standardResolutions = [720, 1080, 1440, 2160]

    /// 1…150 Mbps on a log scale: as much travel from 2 to 10 as from 30 to 150.
    static let bitrateScale = Scale<Int>(
        position: { Float(log(Double($0) / 1e6) / log(150)) },
        value: { p in
            let mbps = pow(150, Double(p))
            let step = mbps < 10 ? 0.5 : 1
            return Int((mbps / step).rounded() * step * 1e6)
        })

    /// 64…320 kbps in steps of 32.
    static let audioScale = Scale<Int>(
        position: { Float($0 - 64_000) / 256_000 },
        value: { p in 64_000 + Int((p * 8).rounded()) * 32_000 })

    /// 0.5…10 s in half seconds.
    static let keyframeScale = Scale<Double>(
        position: { Float(($0 - 0.5) / 9.5) },
        value: { p in 0.5 + (Double(p) * 19).rounded() / 2 })

    private func picture(_ settings: ExportSettings) -> some View {
        PanelSection(title: "Picture") {
            setting(
                "RESOLUTION", settings, Self.resolutionScale, \.resolution,
                detents: Self.standardResolutions.map(Self.resolutionScale.position)
            ) { r in
                let name = r == 2160 ? "4K" : "\(r)p"
                var s = settings
                s.resolution = r
                return "\(name) · \(s.outputWidth)×\(s.outputHeight)"
            }

            keyRow("FRAME RATE", ExportSettings.frameRates, selected: settings.frameRate) {
                "\($0)"
            } set: {
                var s = model.project.exportSettings
                s.frameRate = $0
                model.setExportSettings(s)
            }
            keyRow("CODEC", VideoCodec.allCases, selected: settings.codec, label: codecName) {
                var s = model.project.exportSettings
                s.codec = $0
                model.setExportSettings(s)
            }

            bitrateFader(settings)

            setting(
                "KEYFRAME EVERY", settings, Self.keyframeScale, \.keyframeInterval,
                detents: [Self.keyframeScale.position(2)]
            ) { String(format: "%.1f s", $0) }
        }
        .disabled(isExporting)
    }

    /// The video bitrate, on auto (following resolution, frame rate and codec) until it's moved.
    private func bitrateFader(_ settings: ExportSettings) -> some View {
        let scale = Self.bitrateScale
        return HStack(alignment: .bottom, spacing: 10) {
            Fader(
                title: "VIDEO BITRATE",
                value: scale.position(settings.effectiveVideoBitrate),
                detents: [scale.position(settings.autoVideoBitrate)],
                display: { p in
                    let bits = draft?.videoBitrate ?? (settings.videoBitrate == nil ? nil : scale.value(p))
                    return bits.map(Self.mbps) ?? "AUTO · \(Self.mbps(settings.autoVideoBitrate))"
                },
                onChange: { p in
                    var s = model.project.exportSettings
                    s.videoBitrate = scale.value(p)
                    draft = s
                },
                onCommit: { p in
                    var s = model.project.exportSettings
                    s.videoBitrate = scale.value(p)
                    draft = nil
                    model.setExportSettings(s)
                })
            Button("Auto") {
                var s = model.project.exportSettings
                s.videoBitrate = nil
                model.setExportSettings(s)
            }
            .buttonStyle(StepKeyStyle(isOn: settings.videoBitrate == nil))
            .frame(width: 64)
            .accessibilityHint("Picks a bitrate for the resolution, frame rate and codec.")
        }
    }

    /// A fader for one numeric setting: the readout and guide follow it live, and release is one undo step.
    private func setting<Value>(
        _ title: String, _ settings: ExportSettings, _ scale: Scale<Value>,
        _ key: WritableKeyPath<ExportSettings, Value>, detents: [Float],
        display: @escaping (Value) -> String
    ) -> some View {
        Fader(
            title: title, value: scale.position(settings[keyPath: key]), detents: detents,
            display: { display(scale.value($0)) },
            onChange: { p in
                var s = model.project.exportSettings
                s[keyPath: key] = scale.value(p)
                draft = s
            },
            onCommit: { p in
                var s = model.project.exportSettings
                s[keyPath: key] = scale.value(p)
                draft = nil
                model.setExportSettings(s)
            })
    }

    /// A row of small keys, one lit: a choice among a few fixed values.
    private func keyRow<Value: Hashable>(
        _ title: String, _ values: [Value], selected: Value, label: @escaping (Value) -> String,
        set: @escaping (Value) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button(label(value)) {
                        set(value)
                        Haptics.detent()
                    }
                    .buttonStyle(StepKeyStyle(isOn: value == selected))
                    .accessibilityLabel("\(title.capitalized) \(label(value))")
                }
            }
        }
    }

    private func codecName(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    private static func mbps(_ bits: Int) -> String {
        let m = Double(bits) / 1e6
        return m.rounded() == m && m >= 10 ? "\(Int(m)) Mbps" : String(format: "%.1f Mbps", m)
    }

    // MARK: Guide

    /// What the settings will give: a quality rating, the file size, and notes on anything that
    /// costs size without adding picture (upscaling, frame rates above the footage's).
    private func guide(_ settings: ExportSettings) -> some View {
        let quality = settings.quality
        let hasSound = model.project.exportSoundPolicy != .silent
        let bytes = settings.estimatedBytes(seconds: model.project.duration.seconds, hasSound: hasSound)
        return PanelSection(title: "Guide") {
            HStack(spacing: 0) {
                readout("Quality", quality.label)
                readout("File size", "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                readout("Bits/pixel", String(format: "%.2f", settings.bitsPerPixel))
            }
            .padding(.vertical, 8)
            .recessed(cornerRadius: 12)
            SegmentMeter(
                value: Double(quality.rawValue + 1) / Double(ExportQuality.allCases.count),
                segments: ExportQuality.allCases.count * 4)
            Text(quality.advice).font(.system(size: 13)).foregroundStyle(Theme.label)
            ForEach(notes(settings), id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.signal)
                    Text(note)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func notes(_ settings: ExportSettings) -> [String] {
        var notes: [String] = []
        let sources = model.project.clips.compactMap { model.project.source(for: $0) }
        if let sharpest = sources.map({ min($0.width, $0.height) }).max(), settings.resolution > sharpest {
            notes.append("Your sharpest clip is \(sharpest)p, so above that the picture is enlarged, not sharper.")
        }
        if let fastest = sources.map(\.frameRate).max(), Double(settings.frameRate) > fastest.rounded() + 0.5 {
            notes.append(
                "Your clips run at up to \(Int(fastest.rounded())) fps; \(settings.frameRate) fps repeats frames "
                    + "and makes a bigger file.")
        }
        if settings.resolution > 1080 && !settings.isLandscape {
            notes.append("Instagram and TikTok show 1080p at most; keep 4K for your own master copy.")
        }
        if settings.codec == .hevc {
            notes.append(
                "HEVC plays on Apple devices and most new phones; some Windows PCs and older apps can't open it.")
        }
        if settings.keyframeInterval > 4 {
            notes.append("Long keyframe gaps make the file smaller but slower to scrub in other editors.")
        }
        return notes
    }

    // MARK: Sound

    private var policies: [SoundPolicy] {
        model.project.referenceAudio == nil ? [.clipsOnly, .silent] : [.silent, .clipsOnly, .clipsAndMusic]
    }

    private func soundPicker(_ settings: ExportSettings) -> some View {
        let current = model.project.exportSoundPolicy
        return PanelSection(title: "Sound") {
            ForEach(policies, id: \.self) { policy in
                option(title(policy), detail(policy), isOn: current == policy) { model.setSoundPolicy(policy) }
            }
            if current != .silent {
                setting(
                    "AUDIO BITRATE", settings, Self.audioScale, \.audioBitrate,
                    detents: [128_000, 256_000].map(Self.audioScale.position)
                ) { "\($0 / 1000) kbps" }
                Text("AAC stereo, 48 kHz. 128 kbps is fine for speech; 256 is transparent for music.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
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
            // Until then, clips set to split would render silent.
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

/// A small key in a row of choices: lit (Signal ring) when it's the one chosen.
private struct StepKeyStyle: ButtonStyle {
    var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, weight: .bold))
            .foregroundStyle(isOn ? Theme.signal : Theme.label)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
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
