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
        // A phone that has just woken can take a moment to start audio; time the loop from
        // when playback is actually moving.
        for _ in 0..<50 where engine.currentTime.seconds < 4.05 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        var times: [Double] = []
        for _ in 0..<35 {
            try await Task.sleep(nanoseconds: 100_000_000)
            times.append(engine.currentTime.seconds)
        }
        try skipUnlessInForeground()
        XCTAssertTrue(engine.isPlaying)
        // After 3.5 s of playback from 4 s, it has wrapped and never left the bar.
        XCTAssertTrue(times.allSatisfy { $0 >= 3.95 && $0 <= 6.1 }, "\(times)")
        let player = engine.player
        XCTAssertTrue(
            zip(times, times.dropFirst()).contains { $1 < $0 },
            "never wrapped: \(times); player status \(player.timeControlStatus.rawValue), waiting for "
                + "\(player.reasonForWaitingToPlay?.rawValue ?? "nothing"), item status "
                + "\(player.currentItem?.status.rawValue ?? -1), error \(String(describing: player.currentItem?.error))"
        )
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

    /// Both versions are as long as the sound they came from, and the segments are stitched back
    /// in place: what's left with the voices taken out lines up with the original.
    func testVoiceSeparationKeepsLengthAndTiming() async throws {
        let project = try await makeProject()
        let music = try XCTUnwrap(project.referenceAudio)
        let url = try XCTUnwrap(store.audioURL(for: music, projectID: project.id))
        let source = SourceAsset(fileName: music.fileName, duration: music.duration, width: 0, height: 0, hasAudio: true)
        let voiceURL = store.stemCacheURL(for: source, stem: .voice, projectID: project.id)
        let reducedURL = store.stemCacheURL(for: source, stem: .scene, projectID: project.id)
        try await VoiceSeparator.separate(source: url, voiceURL: voiceURL, reducedURL: reducedURL) { _ in }

        for output in [voiceURL, reducedURL] {
            let duration = try await AVURLAsset(url: output).load(.duration)
            XCTAssertEqual(duration.seconds, music.duration.seconds, accuracy: 0.01, output.lastPathComponent)
        }
        // A click track has no voice, so it stays in the rest, on the beat. Compared at each
        // click's loudest sample: separation smears a little sound just ahead of a click, which
        // moves where it first gets loud but not where it peaks.
        let rate = 44_100.0
        let original = try await monoSamples(in: AVURLAsset(url: url), rate: rate)
        let reduced = try await monoSamples(in: AVURLAsset(url: reducedURL), rate: rate)
        func peak(_ samples: [Float], near seconds: Double) -> Double {
            let window = max(0, Int((seconds - 0.05) * rate))..<min(samples.count, Int((seconds + 0.1) * rate))
            let loudest = window.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
            return Double(loudest) / rate
        }
        let onsets = try await clickOnsets(in: AVURLAsset(url: url))
        XCTAssertGreaterThan(onsets.count, 10)
        for onset in onsets {
            XCTAssertEqual(peak(reduced, near: onset), peak(original, near: onset), accuracy: 0.003, "click at \(onset)")
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

    /// A split clip plays its scene on the clip track and its voices on their own track, each at
    /// the clip's level times its level for that half; clips not split play as recorded.
    func testSplitClipsPlayVoiceAndSceneAtTheirLevels() async throws {
        var project = try await makeProject()
        let split = project.clips[1].id
        try SetClipVolumeCommand(clipID: split, volume: 0.5).apply(to: &project)
        try SetSoundBalanceCommand(clipID: split, balance: SoundBalance(voice: 0.2, scene: 0.8)).apply(to: &project)
        // Clip 2 wants splitting but isn't split yet, so it plays as recorded.
        try SetSoundBalanceCommand(clipID: project.clips[2].id, balance: .removeVoice).apply(to: &project)
        let mix = try XCTUnwrap(
            CompositionBuilder.audioMix(
                project: project, clipAudioTrackID: 1, musicTrackID: nil, voiceTrackID: 3, separated: [split])
                as? AVMutableAudioMix)
        let scene = try XCTUnwrap(mix.inputParameters.first { $0.trackID == 1 })
        let voice = try XCTUnwrap(mix.inputParameters.first { $0.trackID == 3 })
        // Cuts at 4 s and 9 s.
        XCTAssertEqual(level(scene, at: 2), 1)
        XCTAssertEqual(level(voice, at: 2), 0)
        XCTAssertEqual(level(scene, at: 5), 0.4, accuracy: 1e-5)
        XCTAssertEqual(level(voice, at: 5), 0.1, accuracy: 1e-5)
        XCTAssertEqual(level(scene, at: 10), 1, "not split yet: as recorded")
        XCTAssertEqual(level(voice, at: 10), 0)

        // A live drag of the split clip's faders.
        let live = try XCTUnwrap(
            CompositionBuilder.audioMix(
                project: project, clipAudioTrackID: 1, musicTrackID: nil, voiceTrackID: 3, separated: [split],
                balance: (id: split, balance: SoundBalance(voice: 1, scene: 0))) as? AVMutableAudioMix)
        XCTAssertEqual(level(try XCTUnwrap(live.inputParameters.first { $0.trackID == 1 }), at: 5), 0)
        XCTAssertEqual(level(try XCTUnwrap(live.inputParameters.first { $0.trackID == 3 }), at: 5), 0.5, accuracy: 1e-5)

        // Recording the clip fader keeps each half at its level.
        let writing = try XCTUnwrap(
            CompositionBuilder.audioMix(
                project: project, clipAudioTrackID: 1, musicTrackID: nil, voiceTrackID: 3, separated: [split],
                writing: (.clipAudio, 0.6)) as? AVMutableAudioMix)
        XCTAssertEqual(level(try XCTUnwrap(writing.inputParameters.first { $0.trackID == 1 }), at: 5), 0.48, accuracy: 1e-5)
        XCTAssertEqual(level(try XCTUnwrap(writing.inputParameters.first { $0.trackID == 3 }), at: 5), 0.12, accuracy: 1e-5)
        XCTAssertEqual(level(try XCTUnwrap(writing.inputParameters.first { $0.trackID == 1 }), at: 10), 0.6, accuracy: 1e-5)
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

    // MARK: Curve trim

    /// With Write off, a fader moved inside a recorded pass moves that pass (heard live, one undo
    /// step on release); outside any pass it still sets the static level.
    func testFaderInsideARecordedPassTrimsIt() async throws {
        var project = try await makeProject()
        try WriteAutomationCommand(
            target: .music,
            samples: [
                AutomationPoint(time: MediaTime(seconds: 2), value: 0.3),
                AutomationPoint(time: MediaTime(seconds: 4), value: 0.7),
            ]
        ).apply(to: &project)
        try store.save(project)
        let model = WorkspaceModel(project: project, store: store)
        model.open()
        defer { model.close() }
        model.setMode(.mix)
        for _ in 0..<100 where model.engine.duration == .zero {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        model.scrub(to: MediaTime(seconds: 3), precise: true)
        XCTAssertEqual(model.faderLevel(.music), 0.5, accuracy: 1e-3)

        model.faderMoved(.music, to: 0.5)
        model.faderMoved(.music, to: 0.7)
        XCTAssertEqual(envelopeLevel(model.mixProject, .music, at: 3), 0.7, accuracy: 1e-3, "heard while dragging")
        XCTAssertEqual(envelopeLevel(model.project, .music, at: 3), 0.5, accuracy: 1e-3, "not committed yet")
        XCTAssertTrue(model.faderReleased(.music, at: 0.7))
        XCTAssertEqual(model.undoName, "Trim Music Curve")
        XCTAssertEqual(model.faderLevel(.music), 0.7, accuracy: 1e-3)
        XCTAssertEqual(envelopeLevel(model.project, .music, at: 2), 0.5, accuracy: 1e-3, "shape kept")

        model.scrub(to: MediaTime(seconds: 8), precise: true)
        model.faderMoved(.music, to: 0.2)
        XCTAssertFalse(model.faderReleased(.music, at: 0.2))
        model.faderSet(.music, to: 0.2)
        XCTAssertEqual(model.undoName, "Music Level")
        XCTAssertEqual(model.project.referenceAudio?.volume, 0.2)
    }

    /// iOS pauses video playback while the phone is locked, so playback can't be judged then.
    private func skipUnlessInForeground() throws {
        if UIApplication.shared.applicationState != .active {
            throw XCTSkip("The app wasn't in the foreground (phone locked?), so iOS paused playback.")
        }
    }

    // MARK: Jog dial

    /// The dial moves the playhead by whole export frames, shuttles at speed, and inches a selected
    /// curve point along (one undo step per turn).
    func testJogDialMovesByFramesAndInchesAPoint() async throws {
        var project = try await makeProject()
        try WriteAutomationCommand(
            target: .music,
            samples: [
                AutomationPoint(time: MediaTime(seconds: 2), value: 0.3),
                AutomationPoint(time: MediaTime(seconds: 3), value: 0.9),
                AutomationPoint(time: MediaTime(seconds: 5), value: 0.3),
            ]
        ).apply(to: &project)
        try store.save(project)
        let model = WorkspaceModel(project: project, store: store)
        model.open()
        defer { model.close() }
        model.setMode(.mix)
        for _ in 0..<100 where model.engine.duration == .zero {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let fps = Double(project.exportSettings.frameRate)
        model.scrub(to: MediaTime(seconds: 1), precise: true)
        model.jog(by: 3)
        XCTAssertEqual(model.currentTime.seconds, 1 + 3 / fps, accuracy: 1e-4)
        model.jog(by: -1000)
        XCTAssertEqual(model.currentTime, .zero)

        // Pushed out, the dial plays at speed (backwards too) and stops on a frame when let go.
        model.scrub(to: MediaTime(seconds: 6), precise: true)
        model.shuttle(4)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        model.shuttle(nil)
        try skipUnlessInForeground()
        let ahead = model.currentTime.seconds
        XCTAssertGreaterThan(ahead, 8, "4× for a second covers a few seconds")
        XCTAssertFalse(model.engine.isPlaying)
        model.shuttle(-2)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        model.shuttle(nil)
        XCTAssertLessThan(model.currentTime.seconds, ahead - 1, "reverse goes back")
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopped = model.currentTime
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.currentTime, stopped, "let go, it stays put")

        model.curveEditTarget = .music
        model.selectedCurvePoint = (0, 1)
        model.jogCurvePoint(by: 2)
        model.jogCurvePoint(by: 4)
        XCTAssertEqual(model.selectedCurveHandle?.position.time.seconds ?? 0, 3 + 6 / fps, accuracy: 1e-4)
        XCTAssertEqual(model.project.automation.music.segments[0].points[1].time, MediaTime(seconds: 3), "drafted")
        XCTAssertEqual(model.currentTime.seconds, 3 + 6 / fps, accuracy: 1e-4, "the playhead follows the point")
        model.endJog()
        XCTAssertEqual(model.undoName, "Move Curve Point")
        XCTAssertEqual(model.project.automation.music.segments[0].points[1].time.seconds, 3 + 6 / fps, accuracy: 1e-4)
        XCTAssertEqual(model.project.automation.music.segments[0].points[1].value, 0.9)
    }

    // MARK: Watch marks

    /// Marking at the playhead trims the clip playing there: In from that moment, Out up to it.
    func testMarkingAtThePlayheadTrimsTheClipPlaying() async throws {
        let project = try await makeProject()
        let model = WorkspaceModel(project: project, store: store)
        model.open()
        defer { model.close() }
        model.setMode(.mix)
        for _ in 0..<100 where model.engine.duration == .zero {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let second = project.clips[1]
        // Clip 1 plays 0–4 s, so 5 s is one second into clip 2.
        model.scrub(to: MediaTime(seconds: 5), precise: true)
        XCTAssertEqual(model.markAtPlayhead(in: true), 2)
        XCTAssertEqual(model.undoName, "Trim Clip")
        XCTAssertEqual(
            model.project.clip(id: second.id)?.sourceRange.start, second.sourceRange.start + MediaTime(seconds: 1))
        XCTAssertEqual(model.project.clip(id: second.id)?.sourceRange.end, second.sourceRange.end)
        // 2 s into clip 1 (source 2.5 s, since it starts at 0.5 s): Out there.
        model.scrub(to: MediaTime(seconds: 2), precise: true)
        XCTAssertEqual(model.markAtPlayhead(in: false), 1)
        XCTAssertEqual(
            model.project.clips[0].sourceRange,
            MediaTimeRange(start: MediaTime(seconds: 0.5), end: MediaTime(seconds: 2.5)))
        // The playhead now sits where clip 2 follows on. Back in clip 1, clearing puts it back to
        // its whole source; with nothing left to clear, it declines.
        model.scrub(to: MediaTime(seconds: 1), precise: true)
        XCTAssertEqual(model.clearMarksAtPlayhead(), 1)
        XCTAssertEqual(
            model.project.clips[0].sourceRange, model.project.source(for: model.project.clips[0])?.defaultClipRange)
        XCTAssertNil(model.clearMarksAtPlayhead())
    }

    // MARK: Photos

    /// A rotated photo becomes an upright, silent 10 s movie at 30 fps that starts as a 3 s clip
    /// and builds into the sequence like any video.
    func testPhotoBecomesAStillClip() async throws {
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        // Stored sideways with an "upright is portrait" tag, like a phone photo taken in portrait.
        let tagged = UIImage(cgImage: landscape.cgImage!, scale: 1, orientation: .right)
        let data = try XCTUnwrap(tagged.jpegData(compressionQuality: 0.9))
        var project = try store.create(name: "Photo")
        let source = try await MediaImporter.adoptStill(
            imageData: data, originalName: "Photo", label: "Photo", store: store, projectID: project.id)
        XCTAssertTrue(source.isStill)
        XCTAssertFalse(source.hasAudio)
        XCTAssertEqual(source.duration.seconds, StillVideoWriter.duration.seconds, accuracy: 0.05)
        XCTAssertEqual(source.frameRate, 30, accuracy: 0.5)
        // Turned upright: the stored landscape pixels play as portrait.
        let pixels = landscape.cgImage!
        XCTAssertEqual(source.width, pixels.height)
        XCTAssertEqual(source.height, pixels.width)

        try AddClipsCommand(sources: [source]).apply(to: &project)
        XCTAssertEqual(project.duration, SourceAsset.stillClipDuration)
        let built = try await build(project, clipAudio: true, music: false)
        XCTAssertEqual(built.duration.seconds, 3, accuracy: 0.01)
        XCTAssertNil(built.clipAudioTrackID)
    }

    // MARK: Music reference guides

    /// A Quick Click guide renders as the reference track: its clicks play where its offset puts
    /// them, re-saving at a new tempo keeps that placement, it's one undo step, and a Silent export
    /// carries none of it.
    func testQuickClickGuidePlaysOnItsBeatAndStaysOutOfSilentExports() async throws {
        var project = try await makeProject()
        try SetReferenceAudioCommand(track: nil).apply(to: &project)
        try store.save(project)
        let model = WorkspaceModel(project: project, store: store)
        defer { model.close() }

        await model.saveGuide(
            MusicReference(kind: .quickClick, click: ClickGuide(bpm: 100)), named: "Quick Click 100 BPM",
            beatOneAt: MediaTime(seconds: 1))
        let first = try XCTUnwrap(model.project.referenceAudio)
        XCTAssertEqual(first.kind, .quickClick)
        XCTAssertEqual(first.offset, MediaTime(seconds: 1))
        XCTAssertGreaterThanOrEqual(first.duration.seconds, 60 - 0.01, "long enough to keep cutting")
        XCTAssertEqual(model.undoName, "Set Quick Click")

        // Slid in Mix, then re-saved at 120 BPM: it stays where it was put.
        model.setMusicOffset(MediaTime(seconds: 0.4))
        await model.saveGuide(
            MusicReference(kind: .quickClick, click: ClickGuide(bpm: 120)), named: "Quick Click 120 BPM")
        XCTAssertEqual(model.project.referenceAudio?.offset, MediaTime(seconds: 0.4))
        XCTAssertEqual(model.project.referenceAudio?.reference?.click?.bpm, 120)

        // Clip + music: beat one at 0.4 s, then every 0.5 s.
        var heard = model.project
        heard.exportSettings.soundPolicy = .clipsAndMusic
        let loud = try await ExportService.export(project: heard, store: store) { _ in }
        let onsets = try await clickOnsets(in: AVURLAsset(url: loud.videoURL))
        XCTAssertEqual(onsets.count, 26, "\(onsets)")
        for (i, onset) in onsets.enumerated() {
            XCTAssertEqual(onset, 0.4 + Double(i) * 0.5, accuracy: 0.012, "click \(i)")
        }
        // Silent: no sound at all, the guide included.
        var silent = model.project
        silent.exportSettings.soundPolicy = .silent
        let quiet = try await ExportService.export(project: silent, store: store) { _ in }
        let audio = try await AVURLAsset(url: quiet.videoURL).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        let note = try XCTUnwrap(quiet.syncNote)
        XCTAssertEqual(note.referenceKind, "quickClick")
        XCTAssertTrue(note.instruction.contains("0:00.40 into the video"), note.instruction)

        // Undo walks back through each step: the re-save, the slide, the first guide.
        model.undo()
        XCTAssertEqual(model.project.referenceAudio?.reference?.click?.bpm, 100)
        model.undo()
        XCTAssertEqual(model.project.referenceAudio?.offset, MediaTime(seconds: 1))
        model.undo()
        XCTAssertNil(model.project.referenceAudio)
        model.redo()
        XCTAssertEqual(model.project.referenceAudio?.kind, .quickClick)
    }

    /// A Billboards rhythm keeps its uneven spacing all the way into the exported file, survives
    /// reopening the project, and names its song in the handoff.
    func testBillboardsRhythmKeepsItsTimingAndItsSong() async throws {
        var project = try await makeProject()
        try SetReferenceAudioCommand(track: nil).apply(to: &project)
        try store.save(project)
        let model = WorkspaceModel(project: project, store: store)
        defer { model.close() }

        let tapped = [0.0, 0.3, 0.8, 1.1, 1.9]
        let rhythm = TapRhythm(
            mode: .rhythm, taps: tapped.map { TapRhythm.Tap(time: MediaTime(seconds: $0), accent: $0 == 0) })
        let song = SongIdentity(title: "Midnight", artist: "The Reels", section: "chorus")
        await model.saveGuide(
            MusicReference(kind: .billboards, rhythm: rhythm, song: song), named: "Billboards: Midnight",
            beatOneAt: MediaTime(seconds: 0.25))
        XCTAssertEqual(model.undoName, "Set Billboards Guide")
        model.saveNow()

        // Reopened from disk: the taps and the song are as captured.
        let reopened = try store.load(id: project.id)
        let reference = try XCTUnwrap(reopened.referenceAudio?.reference)
        XCTAssertEqual(reference.kind, .billboards)
        XCTAssertEqual(reference.rhythm?.taps.map(\.time.seconds), tapped)
        XCTAssertEqual(reference.song, song)

        var heard = reopened
        heard.exportSettings.soundPolicy = .clipsAndMusic
        let result = try await ExportService.export(project: heard, store: store) { _ in }
        let onsets = try await clickOnsets(in: AVURLAsset(url: result.videoURL))
        XCTAssertEqual(onsets.count, tapped.count, "\(onsets)")
        for (onset, tap) in zip(onsets, tapped) {
            XCTAssertEqual(onset, 0.25 + tap, accuracy: 0.012)
        }
        let note = try XCTUnwrap(result.syncNote)
        XCTAssertEqual(note.songTitle, "Midnight")
        XCTAssertEqual(note.tappedSpotSeconds ?? -1, 0.25, accuracy: 1e-6)
        let sidecar = try XCTUnwrap(result.syncNoteURL)
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains("\"songArtist\" : \"The Reels\""))
    }

    /// Cutting past the end of a guide stretches it, as part of the same edit: one undo takes
    /// back both the new footage and the longer guide, and redo brings both back.
    func testAGuideStretchesWithTheSequenceInTheSameUndoStep() async throws {
        var project = try await makeProject()
        try SetReferenceAudioCommand(track: nil).apply(to: &project)
        try store.save(project)
        let model = WorkspaceModel(project: project, store: store)
        defer { model.close() }
        await model.saveGuide(
            MusicReference(kind: .quickClick, click: ClickGuide(bpm: 120, meter: .threeFour)), named: "Quick Click",
            beatOneAt: MediaTime(seconds: 0.5))
        let short = try XCTUnwrap(model.project.referenceAudio)
        XCTAssertEqual(short.duration.seconds, 60, accuracy: 0.01)

        // Snapping uses the guide's beats: 3/4 at 120 from 0.5 s.
        XCTAssertEqual(model.beatTimes(from: 0, to: 2).map(\.seconds), [0.5, 1, 1.5, 2])

        // Three more passes of the demo clips take the sequence to about 58 s.
        let sources = project.sources
        model.perform(AddClipsCommand(sources: sources + sources + sources))
        let addName = model.undoName
        for _ in 0..<100 where model.project.referenceAudio?.duration == short.duration {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let long = try XCTUnwrap(model.project.referenceAudio)
        XCTAssertGreaterThan(long.duration.seconds, model.project.duration.seconds + 20)
        XCTAssertEqual(long.offset, short.offset, "it stays where it was placed")
        XCTAssertEqual(long.reference, short.reference)
        XCTAssertEqual(model.undoName, addName, "no undo step of its own")

        model.undo()
        XCTAssertEqual(model.project.referenceAudio, short)
        model.redo()
        XCTAssertEqual(model.project.referenceAudio, long)
    }

    // MARK: Crop

    /// A crop pushes in on the exported picture, not just the preview. The source is a still split
    /// red | blue; cropping clip 1 to its left half and clip 2 to its right half turns each whole
    /// frame one colour.
    func testExportedClipsArePushedInOnTheirCrop() async throws {
        let split = UIGraphicsImageRenderer(size: CGSize(width: 540, height: 960)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 270, height: 960))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 270, y: 0, width: 270, height: 960))
        }
        var project = try store.create(name: "Crop")
        let source = try await MediaImporter.adoptStill(
            imageData: try XCTUnwrap(split.pngData()), originalName: "Split", label: "Split", store: store,
            projectID: project.id)
        let add = AddClipsCommand(sources: [source, source])
        try add.apply(to: &project)
        try SetCropCommand(clipID: add.clipIDs[0], crop: Crop(x: 0, y: 0.25, size: 0.5)).apply(to: &project)
        try SetCropCommand(clipID: add.clipIDs[1], crop: Crop(x: 0.5, y: 0.25, size: 0.5)).apply(to: &project)
        try store.save(project)

        let result = try await ExportService.export(project: project, store: store) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result.videoURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (seconds, red) in [(1.5, true), (4.5, false)] {
            let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            for x in [0.1, 0.9] {
                let (r, _, b) = try pixel(frame, x: x, y: 0.5)
                if red {
                    XCTAssertGreaterThan(r, b + 100, "clip 1 at \(x) should be red")
                } else {
                    XCTAssertGreaterThan(b, r + 100, "clip 2 at \(x) should be blue")
                }
            }
        }
    }

    /// The feed cut keeps the centre 4:5 of the 9:16 frame. The still has red bands at its top and
    /// bottom, inside the part the feed drops, so the cut file's edges are green.
    func testFeedExportIsTheCentreFourByFive() async throws {
        let banded = UIGraphicsImageRenderer(size: CGSize(width: 540, height: 960)).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 540, height: 960))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 540, height: 110))
            ctx.fill(CGRect(x: 0, y: 850, width: 540, height: 110))
        }
        var project = try store.create(name: "Feed")
        let source = try await MediaImporter.adoptStill(
            imageData: try XCTUnwrap(banded.pngData()), originalName: "Bands", label: "Bands", store: store,
            projectID: project.id)
        try AddClipsCommand(sources: [source]).apply(to: &project)
        var settings = project.exportSettings
        settings.cutsToFeed = true
        try SetExportSettingsCommand(settings: settings).apply(to: &project)
        try store.save(project)

        let result = try await ExportService.export(project: project, store: store) { _ in }
        let asset = AVURLAsset(url: result.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1350))
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        for y in [0.02, 0.5, 0.98] {
            let (r, g, _) = try pixel(frame, x: 0.5, y: y)
            XCTAssertGreaterThan(g, r + 100, "the feed cut at \(y) should be the green centre")
        }
    }

    /// The colour at a fraction of the way across and down an image.
    private func pixel(_ image: CGImage, x: Double, y: Double) throws -> (Int, Int, Int) {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = CGFloat(x) * CGFloat(image.width)
        let py = CGFloat(y) * CGFloat(image.height)
        context.draw(
            image,
            in: CGRect(
                x: -px, y: -(CGFloat(image.height) - py), width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
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
