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

    // MARK: Helpers

    private func build(_ project: Project, clipAudio: Bool, music: Bool) async throws -> BuiltComposition {
        let store = self.store!
        return try await CompositionBuilder.build(
            project: project, renderSize: CGSize(width: 1080, height: 1920), frameRate: 30,
            includeClipAudio: clipAudio, includeMusic: music,
            mediaURL: { store.mediaURL(for: $0, projectID: project.id) },
            musicURL: project.referenceAudio.flatMap { store.audioURL(for: $0, projectID: project.id) })
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
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let rate = 44_100.0
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
            ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var onsets: [Double] = []
        var index = 0
        var lastLoud = -Int(rate)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            samples.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            for s in samples {
                if abs(s) > 0.1 {
                    if index - lastLoud > Int(rate * 0.2) { onsets.append(Double(index) / rate) }
                    lastLoud = index
                }
                index += 1
            }
        }
        return onsets
    }
}
