import AVFoundation
import EditCore
import XCTest

@testable import PocketInstrument

/// End-to-end checks of the real AVFoundation pipeline with the demo media:
/// three demo clips cut on the beats of the demo click track (120 BPM, a click every 0.5 s).
@MainActor
final class MusicPipelineTests: XCTestCase {
    private var store: ProjectStore!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try ProjectStore(rootURL: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Demo clips (6 s, 5 s, 4 s) with clip A trimmed to 0.5…4.5 s: cuts at 4 s and 9 s, both on clicks.
    private func makeProject(musicOffset: MediaTime = .zero) async throws -> Project {
        var project = try store.create(name: "Sync test")
        let sources = try await DemoMediaGenerator.makeDemoSources(store: store, projectID: project.id)
        let add = AddClipsCommand(sources: sources)
        try add.apply(to: &project)
        try TrimClipCommand(
            clipID: add.clipIDs[0],
            sourceRange: MediaTimeRange(start: MediaTime(seconds: 0.5), end: MediaTime(seconds: 4.5))
        ).apply(to: &project)
        let click = try await DemoMediaGenerator.makeClickTrack(store: store, projectID: project.id)
        XCTAssertEqual(click.duration.seconds, 30, accuracy: 0.01)
        try SetReferenceAudioCommand(track: click).apply(to: &project)
        try SetMusicOffsetCommand(offset: musicOffset).apply(to: &project)
        try store.save(project)
        return project
    }

    func testCutsLandOnClicks() async throws {
        let project = try await makeProject()
        let map = SequenceMap(project: project)
        XCTAssertEqual(map.duration, MediaTime(seconds: 13))
        let beat = MediaTime(seconds: 0.5)
        for entry in map.entries {
            let audio = try XCTUnwrap(map.audioTime(atComposition: entry.compositionRange.start))
            XCTAssertEqual(audio.seconds.truncatingRemainder(dividingBy: beat.seconds), 0, accuracy: 1e-9)
        }
    }

    func testLoopABarPersists() async throws {
        var project = try await makeProject()
        // One 4/4 bar at 120 BPM is 2 s: loop from the first cut (4 s) to 6 s.
        try SetLoopCommand(
            loop: LoopRange.settingStart(MediaTime(seconds: 4), of: nil, sequenceDuration: project.duration)
        )
        .apply(to: &project)
        try SetLoopCommand(
            loop: LoopRange.settingEnd(MediaTime(seconds: 6), of: project.loop, sequenceDuration: project.duration)
        ).apply(to: &project)
        try store.save(project)
        let reopened = try store.load(id: project.id)
        XCTAssertEqual(reopened.loop?.range, MediaTimeRange(start: MediaTime(seconds: 4), end: MediaTime(seconds: 6)))
        XCTAssertEqual(reopened.loop?.isEnabled, true)
    }

    /// The preview player wraps inside the loop range.
    func testPlaybackLoopsTheBar() async throws {
        let project = try await makeProject()
        let built = try await build(project, clipAudio: true, music: true)
        let engine = PlaybackEngine()
        defer { engine.tearDown() }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        let bar = CMTimeRange(start: CMTime(value: 4, timescale: 1), duration: CMTime(value: 2, timescale: 1))
        engine.loopRange = bar
        engine.load(item, duration: built.duration, at: bar.start, resume: true)
        var times: [Double] = []
        for _ in 0..<35 {
            try await Task.sleep(nanoseconds: 100_000_000)
            times.append(engine.currentTime.seconds)
        }
        XCTAssertTrue(engine.isPlaying)
        // After 3.5 s of playback from 4 s, it has wrapped and never left the bar.
        XCTAssertTrue(times.allSatisfy { $0 >= 3.95 && $0 <= 6.1 }, "\(times)")
        XCTAssertTrue(zip(times, times.dropFirst()).contains { $1 < $0 }, "never wrapped: \(times)")
    }

    func testSilentExportHasNoAudioAndWritesSidecar() async throws {
        let project = try await makeProject(musicOffset: MediaTime(seconds: -12.4))
        XCTAssertEqual(project.exportSoundPolicy, .silent)  // default with reference music
        let result = try await ExportService.export(project: project, store: store) { _ in }

        let asset = AVURLAsset(url: result.videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "silent export must have no audio track")
        try await assertVideo(asset, seconds: 13)

        let noteURL = try XCTUnwrap(result.syncNoteURL)
        XCTAssertEqual(
            noteURL.lastPathComponent, result.videoURL.deletingPathExtension().lastPathComponent + ".sync.json")
        let note = try JSONDecoder().decode(MusicSyncNote.self, from: Data(contentsOf: noteURL))
        XCTAssertEqual(note.instruction, "In Instagram, start the song at 0:12.40.")
        XCTAssertEqual(note.referenceFilename, "Demo click 120 BPM")
        XCTAssertEqual(note.compositionDurationSeconds, 13, accuracy: 1e-6)
        XCTAssertEqual(note.exportFilename, result.videoURL.lastPathComponent)
    }

    /// Clip + music: clicks in the exported file sit where the offset puts them.
    func testMusicExportPlacesClicksAtOffset() async throws {
        var project = try await makeProject(musicOffset: MediaTime(seconds: -0.25))
        project.exportSettings.soundPolicy = .clipsAndMusic
        let result = try await ExportService.export(project: project, store: store) { _ in }
        let asset = AVURLAsset(url: result.videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        try await assertVideo(asset, seconds: 13)

        // Song 0.25 s plays at video 0, so clicks land at 0.25, 0.75, 1.25… s.
        let onsets = try await clickOnsets(in: asset)
        XCTAssertEqual(onsets.count, 26, "\(onsets)")
        for (i, onset) in onsets.enumerated() {
            XCTAssertEqual(onset, 0.25 + Double(i) * 0.5, accuracy: 0.012, "click \(i)")
        }
    }

    func testClipAudioOnlyExportLeavesMusicOut() async throws {
        var project = try await makeProject()
        project.exportSettings.soundPolicy = .clipsOnly
        let result = try await ExportService.export(project: project, store: store) { _ in }
        // The demo clips have no sound of their own, so without the music there's nothing to hear.
        let tracks = try await AVURLAsset(url: result.videoURL).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testEachClipsLevelStartsAtItsCut() async throws {
        var project = try await makeProject()
        try SetClipVolumeCommand(clipID: project.clips[1].id, volume: 0).apply(to: &project)
        try SetClipVolumeCommand(clipID: project.clips[2].id, volume: 0.5).apply(to: &project)
        // The demo clips are silent, so check the mix itself against a stand-in clip audio track.
        let mix = try XCTUnwrap(
            CompositionBuilder.audioMix(project: project, clipAudioTrackID: 1, musicTrackID: 2) as? AVMutableAudioMix)
        let clips = try XCTUnwrap(mix.inputParameters.first { $0.trackID == 1 })
        // Cuts at 4 s and 9 s.
        XCTAssertEqual(level(clips, at: 3.9), 1)
        XCTAssertEqual(level(clips, at: 4.0), 0)
        XCTAssertEqual(level(clips, at: 8.9), 0)
        XCTAssertEqual(level(clips, at: 9.0), 0.5)

        // A live fader drag on the selected clip overrides only that clip.
        let live = try XCTUnwrap(
            CompositionBuilder.audioMix(
                project: project, clipAudioTrackID: 1, musicTrackID: nil,
                clipLevel: (id: project.clips[1].id, volume: 0.8)) as? AVMutableAudioMix)
        XCTAssertEqual(live.inputParameters.count, 1)
        XCTAssertEqual(level(live.inputParameters[0], at: 5), 0.8)
        XCTAssertEqual(level(live.inputParameters[0], at: 10), 0.5)
    }

    /// Preview and export share one mix, and it plays the project's level envelopes.
    func testMixFollowsRecordedCurves() async throws {
        var project = try await makeProject()
        try SetClipVolumeCommand(clipID: project.clips[2].id, volume: 0.5).apply(to: &project)
        let s = { (seconds: Double, value: Float) in AutomationPoint(time: MediaTime(seconds: seconds), value: value) }
        try WriteAutomationCommand(target: .music, samples: [s(2, 1), s(3, 0.2), s(5, 0.2), s(6, 0.6)])
            .apply(to: &project)
        try WriteAutomationCommand(target: .clipAudio, samples: [s(8, 0.3), s(10, 0.9)]).apply(to: &project)

        let mix = try XCTUnwrap(
            CompositionBuilder.audioMix(project: project, clipAudioTrackID: 1, musicTrackID: 2) as? AVMutableAudioMix)
        let clips = try XCTUnwrap(mix.inputParameters.first { $0.trackID == 1 })
        let music = try XCTUnwrap(mix.inputParameters.first { $0.trackID == 2 })
        for tenth in 0..<130 {
            let seconds = Double(tenth) / 10
            XCTAssertEqual(
                level(music, at: seconds), envelopeLevel(project, .music, at: seconds), accuracy: 1e-4,
                "music \(seconds)")
            XCTAssertEqual(
                level(clips, at: seconds), envelopeLevel(project, .clipAudio, at: seconds), accuracy: 1e-4,
                "clip \(seconds)")
        }
        XCTAssertEqual(level(music, at: 4), 0.2, accuracy: 1e-4)
        XCTAssertEqual(level(clips, at: 9), 0.6, accuracy: 1e-4)
        XCTAssertEqual(level(clips, at: 12), 0.5, accuracy: 1e-4)

        // A live music fader drag changes the static level but not the recorded pass.
        let live = try XCTUnwrap(
            CompositionBuilder.audioMix(project: project, clipAudioTrackID: nil, musicTrackID: 2, musicLevel: 0.4)
                as? AVMutableAudioMix)
        XCTAssertEqual(level(live.inputParameters[0], at: 1), 0.4, accuracy: 1e-4)
        XCTAssertEqual(level(live.inputParameters[0], at: 4), 0.2, accuracy: 1e-4)
        XCTAssertEqual(level(live.inputParameters[0], at: 10), 0.4, accuracy: 1e-4)
    }

    /// The exported file's loudness follows a recorded music curve: each click's peak, relative
    /// to the same click in an export without the curve, matches the curve at that moment.
    /// (The click track accents every fourth click, so clicks are compared one to one.)
    func testExportedMusicFollowsTheCurve() async throws {
        var project = try await makeProject()
        project.exportSettings.soundPolicy = .clipsAndMusic
        let reference = try await ExportService.export(project: project, store: store) { _ in }
        let flat = try await clickPeaks(in: AVURLAsset(url: reference.videoURL))

        let s = { (seconds: Double, value: Float) in AutomationPoint(time: MediaTime(seconds: seconds), value: value) }
        // Full level, a 2 s fade to 25% from 5 s, held to 9 s, then the glide back to full.
        try WriteAutomationCommand(target: .music, samples: [s(5, 1), s(7, 0.25), s(9, 0.25)]).apply(to: &project)
        let result = try await ExportService.export(project: project, store: store) { _ in }
        let peaks = try await clickPeaks(in: AVURLAsset(url: result.videoURL))
        XCTAssertEqual(peaks.count, 26, "\(peaks.map(\.time))")
        XCTAssertEqual(peaks.count, flat.count)

        var gains: [Double: Float] = [:]
        for (click, unchanged) in zip(peaks, flat) {
            XCTAssertEqual(click.time, unchanged.time, accuracy: 0.002)
            let gain = click.peak / unchanged.peak
            gains[(click.time * 2).rounded() / 2] = gain
            XCTAssertEqual(
                gain, envelopeLevel(project, .music, at: click.time), accuracy: 0.03, "click at \(click.time)")
        }
        XCTAssertEqual(try XCTUnwrap(gains[3]), 1, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(gains[6]), 0.625, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(gains[8]), 0.25, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(gains[10]), 1, accuracy: 0.03)
    }

    // MARK: Helpers

    /// What the project's envelope plays at `seconds`, ramping linearly between breakpoints.
    private func envelopeLevel(_ project: Project, _ target: AutomationTarget, at seconds: Double) -> Float {
        let envelope = project.levelEnvelope(for: target)
        let t = MediaTime(seconds: seconds)
        guard let i = envelope.lastIndex(where: { $0.time <= t }) else { return envelope.first?.value ?? 1 }
        guard i + 1 < envelope.count, envelope[i + 1].time > envelope[i].time else { return envelope[i].value }
        let a = envelope[i]
        let b = envelope[i + 1]
        return a.value + (b.value - a.value) * Float((t - a.time).seconds / (b.time - a.time).seconds)
    }

    private func build(_ project: Project, clipAudio: Bool, music: Bool) async throws -> BuiltComposition {
        let store = self.store!
        return try await CompositionBuilder.build(
            project: project, renderSize: CGSize(width: 1080, height: 1920), frameRate: 30,
            includeClipAudio: clipAudio, includeMusic: music,
            mediaURL: { store.mediaURL(for: $0, projectID: project.id) },
            musicURL: project.referenceAudio.flatMap { store.audioURL(for: $0, projectID: project.id) })
    }

    /// The volume a mix input plays at `seconds`, interpolating inside ramps.
    private func level(_ params: AVAudioMixInputParameters, at seconds: Double) -> Float {
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange()
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        _ = params.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range)
        guard range.duration.isNumeric, range.duration.seconds > 0, start != end else { return start }
        return start + (end - start) * Float((time - range.start).seconds / range.duration.seconds)
    }

    private func assertVideo(_ asset: AVURLAsset, seconds: Double) async throws {
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, seconds, accuracy: 0.05)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
    }

    /// Start times of clicks: the first loud sample after at least 0.2 s of quiet.
    private func clickOnsets(in asset: AVURLAsset) async throws -> [Double] {
        try await clickPeaks(in: asset).map(\.time)
    }

    /// Each click's start time and its loudest sample within 0.1 s.
    private func clickPeaks(in asset: AVURLAsset) async throws -> [(time: Double, peak: Float)] {
        let rate = 44_100.0
        let samples = try await monoSamples(in: asset, rate: rate)
        var clicks: [(time: Double, peak: Float)] = []
        var lastLoud = -Int(rate)
        for (index, s) in samples.enumerated() where abs(s) > 0.02 {
            if index - lastLoud > Int(rate * 0.2) {
                let window = samples[index..<min(samples.count, index + Int(rate * 0.1))]
                clicks.append((Double(index) / rate, window.map(abs).max() ?? 0))
            }
            lastLoud = index
        }
        return clicks
    }

    private func monoSamples(in asset: AVURLAsset, rate: Double) async throws -> [Float] {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
            ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var all: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            samples.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            all += samples
        }
        return all
    }
}
