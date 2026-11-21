import XCTest

@testable import EditCore

final class MediaTimeTests: XCTestCase {
    func testMixedTimescaleArithmeticIsExact() {
        let a = MediaTime(value: 1, timescale: 30)  // 1 frame @30
        let b = MediaTime(value: 1001, timescale: 30000)  // 1 frame @29.97
        let sum = a + b
        XCTAssertEqual(sum.timescale, 30000)
        XCTAssertEqual(sum.value, 1000 + 1001)
    }

    func testEqualityAndHashAcrossTimescales() {
        let a = MediaTime(value: 600, timescale: 600)
        let b = MediaTime(value: 30, timescale: 30)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertLessThan(MediaTime(value: 29, timescale: 30), a)
    }

    func testTimecode() {
        XCTAssertEqual(MediaTime(seconds: 62.5).timecode(frameRate: 30), "01:02:15")
        XCTAssertEqual(MediaTime.zero.timecode(), "00:00:00")
    }
}

final class SequenceMapTests: XCTestCase {
    func makeProject() -> (Project, [SourceAsset]) {
        var p = Project(name: "Test")
        let s1 = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 10), width: 1920, height: 1080)
        let s2 = SourceAsset(fileName: "b.mov", duration: MediaTime(seconds: 4), width: 1080, height: 1920)
        try! AddClipsCommand(sources: [s1, s2]).apply(to: &p)
        return (p, [s1, s2])
    }

    func testMappingAfterTrim() throws {
        var (p, _) = makeProject()
        let first = p.clips[0].id
        try TrimClipCommand(
            clipID: first, sourceRange: MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 5))
        ).apply(to: &p)
        let map = SequenceMap(project: p)
        XCTAssertEqual(map.duration, MediaTime(seconds: 7))
        // Composition 1s is 1s into the first clip, i.e. source 3s.
        let hit = map.sourceTime(atComposition: MediaTime(seconds: 1))
        XCTAssertEqual(hit?.clipID, first)
        XCTAssertEqual(hit?.sourceTime, MediaTime(seconds: 3))
        // Composition 4s lands in clip 2 at source 1s.
        XCTAssertEqual(map.sourceTime(atComposition: MediaTime(seconds: 4))?.sourceTime, MediaTime(seconds: 1))
        XCTAssertEqual(map.compositionTime(clipID: first, sourceTime: MediaTime(seconds: 4)), MediaTime(seconds: 2))
        // End of sequence maps to the last clip.
        XCTAssertEqual(map.entry(at: map.duration)?.clipID, p.clips[1].id)
    }

    func testPhotoStartsAsAShortClipAndCanStretch() throws {
        let photo = SourceAsset(
            fileName: "p.mov", duration: MediaTime(seconds: 10), width: 1080, height: 1440, isStill: true)
        let video = SourceAsset(fileName: "v.mov", duration: MediaTime(seconds: 10), width: 1080, height: 1920)
        var p = Project(name: "Stills")
        try AddClipsCommand(sources: [photo, video]).apply(to: &p)
        XCTAssertEqual(p.clips.map(\.sourceRange.duration), [SourceAsset.stillClipDuration, MediaTime(seconds: 10)])
        try TrimClipCommand(
            clipID: p.clips[0].id, sourceRange: MediaTimeRange(start: .zero, duration: MediaTime(seconds: 8))
        ).apply(to: &p)
        XCTAssertEqual(p.clips[0].compositionDuration, MediaTime(seconds: 8))
    }

    func testSpeedScalesCompositionDuration() {
        var (p, _) = makeProject()
        p.clips[0].speed = 2
        XCTAssertEqual(SequenceMap(project: p).duration, MediaTime(seconds: 9))
        XCTAssertEqual(
            SequenceMap(project: p).sourceTime(atComposition: MediaTime(seconds: 1))?.sourceTime, MediaTime(seconds: 2))
    }
}

final class CommandTests: XCTestCase {
    func testTrimClampsToSourceAndMinimum() throws {
        var (p, _) = SequenceMapTests().makeProject()
        let id = p.clips[1].id
        try TrimClipCommand(
            clipID: id, sourceRange: MediaTimeRange(start: MediaTime(seconds: -1), end: MediaTime(seconds: 99))
        ).apply(to: &p)
        XCTAssertEqual(p.clips[1].sourceRange, MediaTimeRange(start: .zero, duration: MediaTime(seconds: 4)))
        try TrimClipCommand(
            clipID: id,
            sourceRange: MediaTimeRange(start: MediaTime(seconds: 3.99), duration: MediaTime(value: 1, timescale: 600))
        ).apply(to: &p)
        XCTAssertGreaterThanOrEqual(p.clips[1].sourceRange.duration, minimumClipDuration)
        XCTAssertLessThanOrEqual(p.clips[1].sourceRange.end, MediaTime(seconds: 4))
    }

    func testMoveDuplicateRemoveWithUndoRedo() throws {
        var (p, _) = SequenceMapTests().makeProject()
        var undo = UndoStack()
        let original = p
        let a = p.clips[0].id
        let b = p.clips[1].id
        try undo.perform(MoveClipCommand(clipID: a, toIndex: 1), on: &p)
        XCTAssertEqual(p.clips.map(\.id), [b, a])
        try undo.perform(DuplicateClipCommand(clipID: b), on: &p)
        XCTAssertEqual(p.clips.count, 3)
        try undo.perform(RemoveClipCommand(clipID: a), on: &p)
        XCTAssertEqual(p.clips.count, 2)
        XCTAssertEqual(undo.undoActionName, "Remove Clip")

        undo.undo(&p)
        undo.undo(&p)
        undo.undo(&p)
        XCTAssertEqual(p.clips, original.clips)
        XCTAssertFalse(undo.canUndo)
        undo.redo(&p)
        XCTAssertEqual(p.clips.map(\.id), [b, a])
    }

    func testNoOpEditIsNotRecorded() throws {
        var (p, _) = SequenceMapTests().makeProject()
        var undo = UndoStack()
        try undo.perform(MoveClipCommand(clipID: p.clips[0].id, toIndex: 0), on: &p)
        XCTAssertFalse(undo.canUndo)
    }

    func testFailedCommandLeavesProjectUnchanged() {
        var (p, _) = SequenceMapTests().makeProject()
        let before = p
        var undo = UndoStack()
        XCTAssertThrowsError(try undo.perform(RemoveClipCommand(clipID: UUID()), on: &p))
        XCTAssertEqual(p, before)
    }
}

final class ProjectStoreTests: XCTestCase {
    func testRoundTripAndListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(rootURL: root)
        var p = try store.create(name: "Dusk Ride")
        let s = SourceAsset(
            fileName: "x.mov", duration: MediaTime(value: 1001 * 90, timescale: 30000), width: 1080, height: 1920,
            nominalFrameRate: 29.97)
        try AddClipsCommand(sources: [s]).apply(to: &p)
        try TrimClipCommand(
            clipID: p.clips[0].id,
            sourceRange: MediaTimeRange(
                start: MediaTime(value: 1001, timescale: 30000), duration: MediaTime(value: 1001 * 30, timescale: 30000)
            )
        ).apply(to: &p)
        try store.save(p)

        let loaded = try store.load(id: p.id)
        XCTAssertEqual(loaded, p)
        XCTAssertEqual(loaded.clips[0].sourceRange.start.value, 1001)  // exact, not float-rounded
        XCTAssertEqual(store.listProjects().map(\.id), [p.id])
        XCTAssertTrue(store.isMissing(s, projectID: p.id))

        try store.delete(id: p.id)
        XCTAssertTrue(store.listProjects().isEmpty)
    }

    func testTurningToLandscapeSwapsTheFrame() throws {
        var p = Project(name: "Turn")
        var undo = UndoStack()
        try undo.perform(SetOrientationCommand(landscape: true), on: &p)
        XCTAssertEqual([p.exportSettings.width, p.exportSettings.height], [1920, 1080])
        XCTAssertEqual(p.exportSettings.aspectLabel, "16:9")
        XCTAssertEqual(undo.undo(&p), "Horizontal 16:9")
        XCTAssertEqual(p.exportSettings, .vertical1080)
        XCTAssertEqual(p.exportSettings.aspectLabel, "9:16")
    }

    func testCropStaysInsideTheFrameAndUndoes() throws {
        var p = Project(name: "Crop")
        let s = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 4), width: 1920, height: 1080)
        try AddClipsCommand(sources: [s]).apply(to: &p)
        let id = p.clips[0].id
        // Pushed in 2× near the right edge: kept inside the frame.
        let crop = Crop.full.sized(0.5).centred(at: 0.95, 0.5)
        XCTAssertEqual(crop, Crop(x: 0.5, y: 0.25, size: 0.5))
        XCTAssertEqual(Crop(x: 0, y: 0, size: 0.1).size, Crop.minSize)
        var undo = UndoStack()
        try undo.perform(SetCropCommand(clipID: id, crop: crop), on: &p)
        XCTAssertEqual(p.clips[0].crop, crop)
        // It survives a save.
        let data = try ProjectStore.encoder.encode(p)
        XCTAssertEqual(try ProjectStore.decoder.decode(Project.self, from: data).clips[0].crop, crop)
        // A full-frame crop is no crop.
        try undo.perform(SetCropCommand(clipID: id, crop: .full), on: &p)
        XCTAssertNil(p.clips[0].crop)
        XCTAssertEqual(undo.undo(&p), "Reset Crop")
        XCTAssertEqual(undo.undo(&p), "Crop Clip")
        XCTAssertNil(p.clips[0].crop)
    }

    func testFeedCutIsTheCentreFourByFiveOfAVerticalFrame() throws {
        var settings = ExportSettings.vertical1080
        settings.cutsToFeed = true
        XCTAssertEqual([settings.outputWidth, settings.outputHeight], [1080, 1350])
        XCTAssertEqual(settings.outputAspectLabel, "4:5")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), settings)
        // A horizontal sequence has no feed cut.
        let turned = settings.oriented(landscape: true)
        XCTAssertFalse(turned.exportsFeedCut)
        XCTAssertEqual([turned.outputWidth, turned.outputHeight], [1920, 1080])
    }

    func testStorageCountsAndClearsRendersAndCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(rootURL: root)
        let project = try store.create(name: "Space")
        let exports = store.exportsDirectory(for: project.id)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: exports.appendingPathComponent("a.mp4"))
        try Data(count: 50_000).write(to: store.mediaDirectory(for: project.id).appendingPathComponent("b.mov"))
        let track = AudioTrack(fileName: "m.m4a", duration: MediaTime(seconds: 1))
        let cache = store.waveformCacheURL(for: track, projectID: project.id)
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: cache)

        let before = store.usage(for: project.id)
        XCTAssertGreaterThanOrEqual(before.exports, 200_000)
        XCTAssertGreaterThanOrEqual(before.media, 50_000)
        XCTAssertGreaterThanOrEqual(before.cache, 10_000)
        XCTAssertEqual(before.total, before.media + before.exports + before.cache + before.other)

        try store.clearExports(for: project.id)
        try store.clearCache(for: project.id)
        let after = store.usage(for: project.id)
        XCTAssertEqual(after.exports, 0)
        XCTAssertEqual(after.cache, 0)
        XCTAssertEqual(after.media, before.media, "footage stays with the project")
        XCTAssertNoThrow(try store.load(id: project.id))
    }

    func testOlderFileWithMissingFieldsDecodes() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"Old","createdAt":0}
            """
        let p = try ProjectStore.decoder.decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "Old")
        XCTAssertTrue(p.clips.isEmpty)
        XCTAssertEqual(p.exportSettings, .vertical1080)
    }

    func testSoundBalanceSavesUndoesAndOlderClipsKeepTheirChoice() throws {
        var (p, _) = SequenceMapTests().makeProject()
        var undo = UndoStack()
        let id = p.clips[0].id
        XCTAssertNil(p.clips[0].balance)
        try undo.perform(SetSoundBalanceCommand(clipID: id, balance: .removeVoice), on: &p)
        XCTAssertEqual(undo.undoActionName, "Voice & Scene Levels")
        try undo.perform(SetSoundBalanceCommand(clipID: id, balance: SoundBalance(voice: 1.4, scene: 0.3)), on: &p)
        XCTAssertEqual(p.clips[0].balance, SoundBalance(voice: 1, scene: 0.3), "levels stay in 0…1")
        let reopened = try ProjectStore.decoder.decode(Project.self, from: ProjectStore.encoder.encode(p))
        XCTAssertEqual(reopened.clips[0].balance, SoundBalance(voice: 1, scene: 0.3))
        // A duplicate carries the same sound.
        try undo.perform(DuplicateClipCommand(clipID: id), on: &p)
        XCTAssertEqual(p.clips[1].balance, SoundBalance(voice: 1, scene: 0.3))
        undo.undo(&p)
        undo.undo(&p)
        XCTAssertEqual(p.clips[0].balance, .removeVoice)
        undo.undo(&p)
        XCTAssertNil(p.clips[0].balance)

        // Files written before the field existed have no "balance" key; those from before the
        // levels have "voice", which becomes the matching levels.
        let plain = try ProjectStore.encoder.encode(p.clips[0])
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("balance"))
        XCTAssertNil(try ProjectStore.decoder.decode(TimelineClip.self, from: plain).balance)
        func old(_ voice: String) throws -> TimelineClip {
            var json = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
            json["voice"] = voice
            return try ProjectStore.decoder.decode(
                TimelineClip.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertEqual(try old("reduceVoice").balance, .removeVoice)
        XCTAssertEqual(try old("voiceOnly").balance, .voiceOnly)
        let rewritten = try JSONSerialization.jsonObject(with: ProjectStore.encoder.encode(try old("voiceOnly")))
        XCTAssertNil((rewritten as? [String: Any])?["voice"], "the old key isn't written back")
    }

    func testStemsAreClearedWithTheCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(rootURL: root)
        let project = try store.create(name: "Voice")
        let source = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 2), width: 1080, height: 1920)
        var clip = TimelineClip(sourceID: source.id, sourceRange: source.defaultClipRange)
        XCTAssertNil(store.stemURLs(for: clip, source: source, projectID: project.id))
        clip.balance = .removeVoice
        XCTAssertNil(store.stemURLs(for: clip, source: source, projectID: project.id), "not made yet")
        let voice = store.stemCacheURL(for: source, stem: .voice, projectID: project.id)
        let scene = store.stemCacheURL(for: source, stem: .scene, projectID: project.id)
        try FileManager.default.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: voice)
        XCTAssertNil(store.stemURLs(for: clip, source: source, projectID: project.id), "needs both halves")
        try Data([1]).write(to: scene)
        let urls = try XCTUnwrap(store.stemURLs(for: clip, source: source, projectID: project.id))
        XCTAssertEqual(urls.voice, voice)
        XCTAssertEqual(urls.scene, scene)
        try store.clearCache(for: project.id)
        XCTAssertNil(store.stemURLs(for: clip, source: source, projectID: project.id))
    }

    func testClipGainStepsAtTheCuts() throws {
        var (p, _) = SequenceMapTests().makeProject()
        try SetClipVolumeCommand(clipID: p.clips[1].id, volume: 0.5).apply(to: &p)
        let second = p.clips[1].id
        let cut = SequenceMap(project: p).entries[1].compositionRange.start
        let next = SequenceMap(project: p).entries[1].compositionRange.end
        let envelope = p.levelEnvelope(for: .clipAudio) { $0.id == second ? 0.25 : 1 }
        func at(_ t: MediaTime, left: Bool) -> Float? {
            let points = envelope.filter { $0.time == t }
            return left ? points.first?.value : points.last?.value
        }
        XCTAssertEqual(at(.zero, left: false), 1)
        XCTAssertEqual(at(cut, left: true), 1)
        XCTAssertEqual(at(cut, left: false), 0.125, "its own level times its gain")
        XCTAssertEqual(at(next, left: true), 0.125, "to the end")
        // The music ignores clip gains.
        XCTAssertEqual(p.levelEnvelope(for: .music) { _ in 0 }, p.levelEnvelope(for: .music))
    }

    func testNewerSchemaIsRejected() {
        let json = """
            {"schemaVersion":99,"id":"\(UUID().uuidString)","name":"Future","createdAt":0}
            """
        XCTAssertThrowsError(try ProjectStore.decoder.decode(Project.self, from: Data(json.utf8)))
    }
}

final class MusicTests: XCTestCase {
    private func project(seconds: Double) -> Project {
        var p = Project(name: "Music")
        let s = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: seconds), width: 1080, height: 1920)
        try! AddClipsCommand(sources: [s]).apply(to: &p)
        return p
    }

    private func track(seconds: Double, offset: Double = 0) -> AudioTrack {
        AudioTrack(fileName: "m.m4a", duration: MediaTime(seconds: seconds), offset: MediaTime(seconds: offset))
    }

    func testPlacementWhenMusicStartsBeforeVideo() {
        // Song 0 sits 3s before the video starts: video 0 hears song 3s.
        let p = MusicPlacement(track: track(seconds: 60, offset: -3), sequenceDuration: MediaTime(seconds: 10))
        XCTAssertEqual(p?.compositionRange, MediaTimeRange(start: .zero, end: MediaTime(seconds: 10)))
        XCTAssertEqual(p?.audioStart, MediaTime(seconds: 3))
    }

    func testPlacementWhenMusicStartsLateAndEndsEarly() {
        let p = MusicPlacement(track: track(seconds: 4, offset: 2), sequenceDuration: MediaTime(seconds: 10))
        XCTAssertEqual(p?.compositionRange, MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 6)))
        XCTAssertEqual(p?.audioStart, .zero)
    }

    func testNoPlacementWithoutOverlap() {
        XCTAssertNil(MusicPlacement(track: track(seconds: 4, offset: -5), sequenceDuration: MediaTime(seconds: 10)))
        XCTAssertNil(MusicPlacement(track: track(seconds: 4, offset: 10), sequenceDuration: MediaTime(seconds: 10)))
    }

    func testOffsetCommandKeepsMusicInReach() throws {
        var p = project(seconds: 10)
        try SetReferenceAudioCommand(track: track(seconds: 30)).apply(to: &p)
        try SetMusicOffsetCommand(offset: MediaTime(seconds: -100)).apply(to: &p)
        // Only `minimumClipDuration` of the song's end still overlaps the video.
        XCTAssertEqual(p.referenceAudio?.offset, MediaTime.zero - (MediaTime(seconds: 30) - minimumClipDuration))
        try SetMusicOffsetCommand(offset: MediaTime(seconds: 100)).apply(to: &p)
        XCTAssertEqual(p.referenceAudio?.offset, MediaTime(seconds: 10) - minimumClipDuration)
        XCTAssertNotNil(MusicPlacement(track: p.referenceAudio!, sequenceDuration: p.duration))
    }

    func testVolumesClampAndMusicVolumeNeedsMusic() throws {
        var p = project(seconds: 10)
        try SetClipVolumeCommand(clipID: p.clips[0].id, volume: 1.7).apply(to: &p)
        XCTAssertEqual(p.clips[0].volume, 1)
        XCTAssertThrowsError(try SetClipVolumeCommand(clipID: UUID(), volume: 0.5).apply(to: &p))
        XCTAssertThrowsError(try SetMusicVolumeCommand(volume: 0.5).apply(to: &p))
        try SetReferenceAudioCommand(track: track(seconds: 30)).apply(to: &p)
        try SetMusicVolumeCommand(volume: -1).apply(to: &p)
        XCTAssertEqual(p.referenceAudio?.volume, 0)
    }

    func testEachClipKeepsItsOwnLevel() throws {
        var p = Project(name: "Levels")
        let sources = (0..<3).map { _ in
            SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 2), width: 1080, height: 1920)
        }
        try AddClipsCommand(sources: sources).apply(to: &p)
        var undo = UndoStack()
        try undo.perform(SetClipVolumeCommand(clipID: p.clips[1].id, volume: 0.25), on: &p)
        XCTAssertEqual(p.clips.map(\.volume), [1, 0.25, 1])
        // The level travels with the clip when it moves, and survives saving.
        try undo.perform(MoveClipCommand(clipID: p.clips[1].id, toIndex: 0), on: &p)
        XCTAssertEqual(p.clips.map(\.volume), [0.25, 1, 1])
        let decoded = try ProjectStore.decoder.decode(Project.self, from: ProjectStore.encoder.encode(p))
        XCTAssertEqual(decoded.clips.map(\.volume), [0.25, 1, 1])
        undo.undo(&p)
        undo.undo(&p)
        XCTAssertEqual(p.clips.map(\.volume), [1, 1, 1])
    }

    func testLoopIsFittedToSequence() throws {
        var p = project(seconds: 10)
        let wide = LoopRange(range: MediaTimeRange(start: MediaTime(seconds: 8), end: MediaTime(seconds: 20)))
        try SetLoopCommand(loop: wide).apply(to: &p)
        XCTAssertEqual(p.loop?.range, MediaTimeRange(start: MediaTime(seconds: 8), end: MediaTime(seconds: 10)))
        let past = LoopRange(range: MediaTimeRange(start: MediaTime(seconds: 12), end: MediaTime(seconds: 13)))
        XCTAssertEqual(past.clamped(toSequence: MediaTime(seconds: 10))?.range.end, MediaTime(seconds: 10))
        XCTAssertNil(past.clamped(toSequence: .zero))
    }

    func testWaveformEnvelopeAndCache() {
        let w = Waveform(peaksPerSecond: 10, peaks: (0..<20).map { Float($0) / 20 })
        // 2s of audio in 2 buckets: max of each second.
        XCTAssertEqual(w.envelope(from: .zero, to: MediaTime(seconds: 2), buckets: 2), [0.45, 0.95])
        // Before the song starts reads as silence.
        XCTAssertEqual(w.envelope(from: MediaTime(seconds: -2), to: .zero, buckets: 2), [0, 0])
        XCTAssertEqual(Waveform(data: w.data), w)
        XCTAssertNil(Waveform(data: Data([1, 2, 3])))
    }

    // MARK: Audio-reference mapping

    func testSequenceMapAudioTimeWithPositiveOffset() throws {
        var p = project(seconds: 10)
        try SetReferenceAudioCommand(track: track(seconds: 30, offset: 2)).apply(to: &p)
        let map = SequenceMap(project: p)
        // Song 0 enters 2s into the video; before that the song position is negative (silence).
        XCTAssertEqual(map.audioTime(atComposition: MediaTime(seconds: 5)), MediaTime(seconds: 3))
        XCTAssertEqual(map.audioTime(atComposition: .zero), MediaTime(seconds: -2))
        XCTAssertEqual(map.compositionTime(atAudio: .zero), MediaTime(seconds: 2))
    }

    func testSequenceMapAudioTimeWithNegativeOffset() throws {
        // The song starts 12.4s before the video: the first frame hears song 12.4s.
        var p = project(seconds: 10)
        try SetReferenceAudioCommand(track: track(seconds: 60, offset: -12.4)).apply(to: &p)
        let map = SequenceMap(project: p)
        XCTAssertEqual(map.audioTime(atComposition: .zero), MediaTime(seconds: 12.4))
        XCTAssertEqual(map.audioTime(atComposition: MediaTime(seconds: 1)), MediaTime(seconds: 13.4))
        let back = map.compositionTime(atAudio: MediaTime(seconds: 13.4))
        XCTAssertEqual(back, MediaTime(seconds: 1))
        XCTAssertEqual(map.compositionTime(atAudio: .zero), MediaTime(seconds: -12.4))
    }

    func testSequenceMapWithoutMusicHasNoAudioTime() {
        let map = SequenceMap(project: project(seconds: 10))
        XCTAssertNil(map.audioTime(atComposition: .zero))
        XCTAssertNil(map.compositionTime(atAudio: .zero))
    }

    // MARK: Offset commands

    func testFrameAndMillisecondNudgesAreExactAndUndoable() throws {
        var p = project(seconds: 10)
        var undo = UndoStack()
        try undo.perform(SetReferenceAudioCommand(track: track(seconds: 30)), on: &p)
        let frame = MediaTime(value: 1, timescale: 30)
        let tenMs = MediaTime(value: 10, timescale: 1000)
        try undo.perform(SetMusicOffsetCommand(offset: p.referenceAudio!.offset - frame), on: &p)
        try undo.perform(SetMusicOffsetCommand(offset: p.referenceAudio!.offset + tenMs), on: &p)
        // −1/30 s + 10 ms, held exactly as a rational.
        XCTAssertEqual(p.referenceAudio?.offset, MediaTime(value: -70, timescale: 3000))
        XCTAssertEqual(undo.undo(&p), "Move Music")
        XCTAssertEqual(p.referenceAudio?.offset, MediaTime.zero - frame)
        XCTAssertEqual(undo.undo(&p), "Move Music")
        XCTAssertEqual(p.referenceAudio?.offset, .zero)
        XCTAssertEqual(undo.undo(&p), "Set Music")
        XCTAssertNil(p.referenceAudio)
    }

    func testReplaceAndRemoveMusicAreUndoable() throws {
        var p = project(seconds: 10)
        var undo = UndoStack()
        let first = track(seconds: 30)
        var second = track(seconds: 20)
        second.fileName = "b.wav"
        try undo.perform(SetReferenceAudioCommand(track: first), on: &p)
        try undo.perform(SetReferenceAudioCommand(track: second), on: &p)
        try undo.perform(SetReferenceAudioCommand(track: nil), on: &p)
        XCTAssertNil(p.referenceAudio)
        undo.undo(&p)
        XCTAssertEqual(p.referenceAudio?.fileName, "b.wav")
        undo.undo(&p)
        XCTAssertEqual(p.referenceAudio, first)
    }

    // MARK: Loop ranges

    func testLoopInAndOutAtPlayhead() {
        let d = MediaTime(seconds: 10)
        let bar = LoopRange(range: MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 4)))
        // Loop In inside the current loop keeps its end.
        XCTAssertEqual(
            LoopRange.settingStart(MediaTime(seconds: 3), of: bar, sequenceDuration: d)?.range,
            MediaTimeRange(start: MediaTime(seconds: 3), end: MediaTime(seconds: 4)))
        // Loop In after the current end loops to the end of the sequence.
        XCTAssertEqual(
            LoopRange.settingStart(MediaTime(seconds: 6), of: bar, sequenceDuration: d)?.range,
            MediaTimeRange(start: MediaTime(seconds: 6), end: d))
        // Loop Out after the start keeps the start; before it, loops from 0.
        XCTAssertEqual(
            LoopRange.settingEnd(MediaTime(seconds: 8), of: bar, sequenceDuration: d)?.range,
            MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 8)))
        XCTAssertEqual(
            LoopRange.settingEnd(MediaTime(seconds: 1), of: bar, sequenceDuration: d)?.range,
            MediaTimeRange(start: .zero, end: MediaTime(seconds: 1)))
        // Without a loop: In → to the end, Out → from 0. Both come back enabled.
        let fresh = LoopRange.settingStart(MediaTime(seconds: 9.99), of: nil, sequenceDuration: d)
        XCTAssertEqual(fresh?.range.end, d)
        XCTAssertEqual(fresh?.range.duration, minimumClipDuration)
        XCTAssertEqual(fresh?.isEnabled, true)
        XCTAssertNil(LoopRange.settingEnd(.zero, of: nil, sequenceDuration: .zero))
    }

    func testLoopToggleIsUndoableAndPersists() throws {
        var p = project(seconds: 10)
        var undo = UndoStack()
        let bar = LoopRange(range: MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 4)))
        try undo.perform(SetLoopCommand(loop: bar), on: &p)
        var off = bar
        off.isEnabled = false
        try undo.perform(SetLoopCommand(loop: off), on: &p)
        XCTAssertEqual(p.loop?.isEnabled, false)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.loop, off)
        undo.undo(&p)
        XCTAssertEqual(p.loop, bar)
    }

    // MARK: Export sound policy

    func testSoundPolicyDefaultsToSilentWithMusic() throws {
        var p = project(seconds: 10)
        XCTAssertEqual(p.exportSoundPolicy, .clipsOnly)
        try SetReferenceAudioCommand(track: track(seconds: 30)).apply(to: &p)
        XCTAssertEqual(p.exportSoundPolicy, .silent)
        p.exportSettings.soundPolicy = .clipsAndMusic
        XCTAssertEqual(p.exportSoundPolicy, .clipsAndMusic)
        // A chosen "clips + music" means clip sound once the music is removed.
        try SetReferenceAudioCommand(track: nil).apply(to: &p)
        XCTAssertEqual(p.exportSoundPolicy, .clipsOnly)
        XCTAssertFalse(SoundPolicy.silent.includesClipAudio || SoundPolicy.silent.includesMusic)
        XCTAssertFalse(SoundPolicy.clipsOnly.includesMusic)
    }

    func testExportSettingsRoundTripWithoutLegacyKeys() throws {
        let settings = ExportSettings(soundPolicy: .clipsAndMusic)
        let data = try JSONEncoder().encode(settings)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("includeClipAudio"))
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), settings)
    }

    // MARK: Older project files

    /// A project.json exactly as Phase 1 wrote it (no music, no loop, includeClipAudio flag).
    private func phase1JSON(includeClipAudio: Bool, clipAudioVolume: Float = 1) -> String {
        """
        {
          "clipAudioVolume" : \(clipAudioVolume),
          "clips" : [
            {
              "framing" : "fill",
              "id" : "6B1F1D1C-6C1A-4F55-9E0E-0A8C0C9B6A01",
              "sourceID" : "0F8F3C2E-1E9B-4A2B-8F3B-7E2F0C1D2A01",
              "sourceRange" : {
                "duration" : { "timescale" : 600, "value" : 1800 },
                "start" : { "timescale" : 30, "value" : 15 }
              },
              "speed" : 1
            }
          ],
          "createdAt" : 784900000.5,
          "exportSettings" : {
            "frameRate" : 30,
            "height" : 1920,
            "includeClipAudio" : \(includeClipAudio),
            "width" : 1080
          },
          "id" : "A0F1B2C3-D4E5-4F60-8172-93A4B5C6D7E8",
          "modifiedAt" : 784900100.25,
          "name" : "Beach day",
          "schemaVersion" : 1,
          "sources" : [
            {
              "duration" : { "timescale" : 600, "value" : 3600 },
              "fileName" : "4C1D.mov",
              "hasAudio" : true,
              "height" : 1920,
              "id" : "0F8F3C2E-1E9B-4A2B-8F3B-7E2F0C1D2A01",
              "importedAt" : 784900000.5,
              "nominalFrameRate" : 29.97,
              "originalFilename" : "IMG_0001.MOV",
              "width" : 1080
            }
          ],
          "volumeAutomation" : [ ]
        }
        """
    }

    func testPhase1ProjectFileStillOpens() throws {
        let p = try ProjectStore.decoder.decode(Project.self, from: Data(phase1JSON(includeClipAudio: true).utf8))
        XCTAssertEqual(p.name, "Beach day")
        XCTAssertEqual(p.clips.count, 1)
        XCTAssertEqual(p.clips[0].sourceRange.start, MediaTime(seconds: 0.5))
        XCTAssertEqual(p.duration, MediaTime(seconds: 3))
        XCTAssertNil(p.referenceAudio)
        XCTAssertNil(p.loop)
        XCTAssertNil(p.exportSettings.soundPolicy)
        XCTAssertEqual(p.exportSoundPolicy, .clipsOnly)

        let silent = try ProjectStore.decoder.decode(
            Project.self, from: Data(phase1JSON(includeClipAudio: false).utf8))
        XCTAssertEqual(silent.exportSettings.soundPolicy, .silent)
        XCTAssertEqual(silent.clips[0].volume, 1)

        // The old single clip level becomes each clip's own level, and isn't written back.
        let quiet = try ProjectStore.decoder.decode(
            Project.self, from: Data(phase1JSON(includeClipAudio: true, clipAudioVolume: 0.4).utf8))
        XCTAssertEqual(quiet.clips[0].volume, 0.4)
        let rewritten = String(decoding: try ProjectStore.encoder.encode(quiet), as: UTF8.self)
        XCTAssertFalse(rewritten.contains("clipAudioVolume"))
        XCTAssertEqual(try ProjectStore.decoder.decode(Project.self, from: Data(rewritten.utf8)).clips[0].volume, 0.4)

        // Saving rewrites it in the current format, and it still reads back the same.
        let again = try ProjectStore.decoder.decode(Project.self, from: ProjectStore.encoder.encode(silent))
        XCTAssertEqual(again, silent)
    }

    // MARK: Sync note

    func testSyncNoteForSongStartingBeforeVideo() throws {
        var p = project(seconds: 10)
        var music = track(seconds: 60, offset: -12.4)
        music.originalFilename = "Song.m4a"
        try SetReferenceAudioCommand(track: music).apply(to: &p)
        let note = try XCTUnwrap(MusicSyncNote(project: p, exportFilename: "Out.mp4"))
        XCTAssertEqual(note.instruction, "In Instagram, start the song at 0:12.40.")
        XCTAssertEqual(note.referenceFilename, "Song.m4a")
        XCTAssertEqual(note.offsetSeconds, -12.4, accuracy: 1e-9)
        XCTAssertEqual(note.compositionDurationSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(note.soundPolicy, .silent)
        let decoded = try JSONDecoder().decode(MusicSyncNote.self, from: note.jsonData)
        XCTAssertEqual(decoded, note)
    }

    func testSyncNoteForSongEnteringLate() throws {
        var p = project(seconds: 10)
        try SetReferenceAudioCommand(track: track(seconds: 60, offset: 1.2)).apply(to: &p)
        let note = try XCTUnwrap(MusicSyncNote(project: p))
        XCTAssertTrue(note.instruction.hasPrefix("In Instagram, start the song at 0:00.00."))
        XCTAssertTrue(note.instruction.contains("0:01.20"))
        XCTAssertNil(MusicSyncNote(project: project(seconds: 10)))
        XCTAssertEqual(MusicSyncNote.clock(72.405), "1:12.41")
    }
}
