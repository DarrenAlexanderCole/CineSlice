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

    func testOlderFileWithMissingFieldsDecodes() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"Old","createdAt":0}
            """
        let p = try ProjectStore.decoder.decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "Old")
        XCTAssertTrue(p.clips.isEmpty)
        XCTAssertEqual(p.exportSettings, .vertical1080)
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

    func testAudioReferenceMappingRoundTrips() {
        let t = track(seconds: 60, offset: -3)
        let audio = t.audioTime(atComposition: MediaTime(seconds: 1))
        XCTAssertEqual(audio, MediaTime(seconds: 4))
        XCTAssertEqual(t.compositionTime(atAudio: audio), MediaTime(seconds: 1))
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
        try SetClipAudioVolumeCommand(volume: 1.7).apply(to: &p)
        XCTAssertEqual(p.clipAudioVolume, 1)
        XCTAssertThrowsError(try SetMusicVolumeCommand(volume: 0.5).apply(to: &p))
        try SetReferenceAudioCommand(track: track(seconds: 30)).apply(to: &p)
        try SetMusicVolumeCommand(volume: -1).apply(to: &p)
        XCTAssertEqual(p.referenceAudio?.volume, 0)
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

    func testSoundPolicyMapsToFlags() {
        var s = ExportSettings()
        XCTAssertEqual(s.soundPolicy, .clipsAndMusic)
        s.soundPolicy = .musicOnly
        XCTAssertFalse(s.includeClipAudio)
        XCTAssertTrue(s.includeMusic)
        s.soundPolicy = .silent
        XCTAssertEqual(s.soundPolicy, .silent)
    }

    func testPhase1ExportSettingsStillDecode() throws {
        let json = #"{"width":1080,"height":1920,"frameRate":30,"includeClipAudio":false}"#
        let s = try JSONDecoder().decode(ExportSettings.self, from: Data(json.utf8))
        XCTAssertFalse(s.includeClipAudio)
        XCTAssertTrue(s.includeMusic)
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
}
