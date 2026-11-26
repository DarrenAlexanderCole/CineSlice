import XCTest

@testable import EditCore

final class SoundTests: XCTestCase {
    private func sound(_ seconds: Double, at start: Double, id: UUID = UUID()) -> SoundClip {
        SoundClip(
            id: id, fileName: "s.m4a", fileDuration: MediaTime(seconds: seconds), start: MediaTime(seconds: start))
    }

    private func apply(_ command: EditingCommand, to project: inout Project) throws {
        try command.apply(to: &project)
    }

    func testAddingFindsARoomyLaneOrMakesOne() throws {
        var p = Project(name: "Sounds")
        try apply(AddSoundCommand(clip: sound(4, at: 0)), to: &p)
        XCTAssertEqual(p.soundTracks.count, 1)
        // Overlaps the first: goes on a new lane.
        try apply(AddSoundCommand(clip: sound(4, at: 2)), to: &p)
        XCTAssertEqual(p.soundTracks.count, 2)
        // Clear of the first lane's sound: joins it, in time order.
        try apply(AddSoundCommand(clip: sound(1, at: 5)), to: &p)
        XCTAssertEqual(p.soundTracks.count, 2)
        XCTAssertEqual(p.soundTracks[0].clips.map(\.start.seconds), [0, 5])
        // Asked for the second lane and clear there.
        try apply(AddSoundCommand(clip: sound(1, at: 7), preferredTrack: 1), to: &p)
        XCTAssertEqual(p.soundTracks[1].clips.count, 2)
    }

    func testLanesStopAtTheLimit() throws {
        var p = Project(name: "Full")
        for _ in 0..<Project.maxSoundTracks { try apply(AddSoundCommand(clip: sound(4, at: 0)), to: &p) }
        XCTAssertThrowsError(try apply(AddSoundCommand(clip: sound(4, at: 1)), to: &p)) {
            XCTAssertEqual($0 as? EditError, .noRoom)
        }
    }

    func testMovingKeepsLanesClearAndDropsEmptyOnes() throws {
        var p = Project(name: "Move")
        let a = UUID()
        let b = UUID()
        try apply(AddSoundCommand(clip: sound(2, at: 0, id: a)), to: &p)
        try apply(AddSoundCommand(clip: sound(2, at: 1, id: b)), to: &p)
        XCTAssertEqual(p.soundLocation(id: b)?.track, 1)
        // Onto a's lane where it would overlap: refused, nothing changes.
        let before = p
        XCTAssertThrowsError(try apply(MoveSoundCommand(clipID: b, track: 0, start: MediaTime(seconds: 1)), to: &p))
        XCTAssertEqual(p, before)
        // After a: fits; its old lane is empty and goes.
        try apply(MoveSoundCommand(clipID: b, track: 0, start: MediaTime(seconds: 2)), to: &p)
        XCTAssertEqual(p.soundTracks.count, 1)
        XCTAssertEqual(p.soundTracks[0].clips.map(\.id), [a, b])
        // Onto a new lane under the others, never before 0.
        try apply(MoveSoundCommand(clipID: a, track: 1, start: MediaTime(seconds: -3)), to: &p)
        XCTAssertEqual(p.soundTracks.count, 2)
        XCTAssertEqual(p.sound(id: a)?.start, .zero)
    }

    func testSplitKeepsTheFileMapping() throws {
        var p = Project(name: "Split")
        let id = UUID()
        var clip = sound(10, at: 3, id: id)
        clip.sourceRange = MediaTimeRange(start: MediaTime(seconds: 1), duration: MediaTime(seconds: 6))
        try apply(AddSoundCommand(clip: clip), to: &p)
        let second = UUID()
        try apply(SplitSoundCommand(clipID: id, time: MediaTime(seconds: 5), newClipID: second), to: &p)
        let halves = p.soundTracks[0].clips
        XCTAssertEqual(halves.map(\.id), [id, second])
        XCTAssertEqual(
            halves[0].sourceRange, MediaTimeRange(start: MediaTime(seconds: 1), duration: MediaTime(seconds: 2)))
        XCTAssertEqual(halves[1].start, MediaTime(seconds: 5))
        XCTAssertEqual(
            halves[1].sourceRange, MediaTimeRange(start: MediaTime(seconds: 3), duration: MediaTime(seconds: 4)))
        XCTAssertThrowsError(try apply(SplitSoundCommand(clipID: id, time: MediaTime(seconds: 3)), to: &p))
    }

    func testLevelAndFadesStayInRange() throws {
        var p = Project(name: "Level")
        let a = UUID()
        try apply(AddSoundCommand(clip: sound(4, at: 1, id: a)), to: &p)
        try apply(SetSoundLevelCommand(clipID: a, volume: 1.7), to: &p)
        XCTAssertEqual(p.sound(id: a)?.volume, 1)
        try apply(SetSoundLevelCommand(clipID: a, volume: 0.25), to: &p)
        XCTAssertEqual(p.sound(id: a)?.volume, 0.25)
        // Fades longer than the sound are cut back, the fade in first.
        try apply(
            SetSoundFadesCommand(clipID: a, fadeIn: MediaTime(seconds: 3), fadeOut: MediaTime(seconds: 3)), to: &p)
        XCTAssertEqual(p.sound(id: a)?.fadeIn.seconds, 3)
        XCTAssertEqual(p.sound(id: a)?.fadeOut.seconds, 1)
        try apply(
            SetSoundFadesCommand(clipID: a, fadeIn: MediaTime(seconds: -1), fadeOut: MediaTime(seconds: 9)), to: &p)
        XCTAssertEqual(p.sound(id: a)?.fadeIn, .zero)
        XCTAssertEqual(p.sound(id: a)?.fadeOut.seconds, 4)
    }

    func testSplittingSharesTheFades() throws {
        var p = Project(name: "Split fades")
        let a = UUID()
        let b = UUID()
        try apply(AddSoundCommand(clip: sound(4, at: 0, id: a)), to: &p)
        try apply(
            SetSoundFadesCommand(clipID: a, fadeIn: MediaTime(seconds: 1.5), fadeOut: MediaTime(seconds: 1)), to: &p)
        try apply(SplitSoundCommand(clipID: a, time: MediaTime(seconds: 1), newClipID: b), to: &p)
        // The first half is shorter than its fade in, which is cut back to fit.
        XCTAssertEqual(p.sound(id: a)?.fadeIn.seconds, 1)
        XCTAssertEqual(p.sound(id: a)?.fadeOut, .zero)
        XCTAssertEqual(p.sound(id: b)?.fadeIn, .zero)
        XCTAssertEqual(p.sound(id: b)?.fadeOut.seconds, 1)
    }

    func testEnvelopeRampsFadesAndIsSilentBetweenSoundsAndWhenMuted() throws {
        var p = Project(name: "Envelope")
        let a = UUID()
        try apply(AddSoundCommand(clip: sound(2, at: 1, id: a)), to: &p)
        try apply(AddSoundCommand(clip: sound(1, at: 4)), to: &p)
        try apply(SetSoundLevelCommand(clipID: a, volume: 0.5), to: &p)
        try apply(
            SetSoundFadesCommand(clipID: a, fadeIn: MediaTime(seconds: 0.5), fadeOut: MediaTime(seconds: 1)), to: &p)
        let points = p.soundTracks[0].levelEnvelope.map { [$0.time.seconds, Double($0.value)] }
        XCTAssertEqual(
            points,
            [
                [0, 0], [1, 0],  // silent until the first sound
                [1.5, 0.5], [2, 0.5], [3, 0],  // up over half a second, held, down over a second
                [4, 0],  // silent between
                [4, 1], [5, 1],  // the second sound, no fades: a step up
            ])
        try apply(SetSoundTrackMuteCommand(trackID: p.soundTracks[0].id, isMuted: true), to: &p)
        XCTAssertEqual(p.soundTracks[0].levelEnvelope.map(\.value), [0])
        XCTAssertEqual(
            SetSoundTrackMuteCommand(trackID: p.soundTracks[0].id, isMuted: true).actionName, "Mute Lane")
    }

    func testFadesSaveOnlyWhenSet() throws {
        var clip = sound(3, at: 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(clip), as: UTF8.self).contains("fade"))
        clip.fadeIn = MediaTime(seconds: 0.5)
        let decoded = try JSONDecoder().decode(SoundClip.self, from: try JSONEncoder().encode(clip))
        XCTAssertEqual(decoded, clip)
    }

    func testRemovingTheLastSoundRemovesItsLane() throws {
        var p = Project(name: "Remove")
        let id = UUID()
        try apply(AddSoundCommand(clip: sound(2, at: 0, id: id)), to: &p)
        try apply(RemoveSoundCommand(clipID: id), to: &p)
        XCTAssertTrue(p.soundTracks.isEmpty)
    }

    func testProjectsWithoutSoundsStillSaveAsVersionOne() throws {
        var p = Project(name: "Plain")
        let plain = String(decoding: try ProjectStore.encoder.encode(p), as: UTF8.self)
        XCTAssertTrue(plain.contains("\"schemaVersion\" : 1"))
        XCTAssertFalse(plain.contains("soundTracks"))

        try apply(AddSoundCommand(clip: sound(2, at: 1)), to: &p)
        let data = try ProjectStore.encoder.encode(p)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\" : 2"))
        XCTAssertEqual(try ProjectStore.decoder.decode(Project.self, from: data), p)
    }

    func testVersionTwoIsReadAndThreeIsRefused() throws {
        let id = UUID().uuidString
        let v2 = """
            {"schemaVersion":2,"id":"\(id)","name":"Two","createdAt":0,
             "soundTracks":[{"id":"\(UUID().uuidString)","isMuted":false,"clips":[
               {"id":"\(UUID().uuidString)","fileName":"a.m4a","fileDuration":{"value":1200,"timescale":600},
                "sourceRange":{"start":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600}},
                "start":{"value":300,"timescale":600},"volume":0.5}]}]}
            """
        let p = try ProjectStore.decoder.decode(Project.self, from: Data(v2.utf8))
        XCTAssertEqual(p.soundTracks.first?.clips.first?.start, MediaTime(seconds: 0.5))
        let v3 = #"{"schemaVersion":3,"id":"\#(id)","name":"Three","createdAt":0}"#
        XCTAssertThrowsError(try ProjectStore.decoder.decode(Project.self, from: Data(v3.utf8)))
    }
}

final class GapTests: XCTestCase {
    /// Three clips of 2, 3 and 4 s, back to back.
    private func project() throws -> (Project, [UUID]) {
        var p = Project(name: "Gaps")
        let sources = [2.0, 3, 4].map {
            SourceAsset(fileName: "\($0).mov", duration: MediaTime(seconds: $0), width: 1080, height: 1920)
        }
        let add = AddClipsCommand(sources: sources)
        try add.apply(to: &p)
        return (p, add.clipIDs)
    }

    private func starts(_ p: Project) -> [Double] {
        SequenceMap(project: p).entries.map(\.compositionRange.start.seconds)
    }

    func testMovingIntoClearTimeLeavesGapsAndMovesNothingElse() throws {
        var (p, ids) = try project()
        // The first clip to 12 s: the others stay at 2 and 5; it now sits after a gap.
        try PlaceClipCommand(clipID: ids[0], start: MediaTime(seconds: 12)).apply(to: &p)
        XCTAssertEqual(p.clips.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(starts(p), [2, 5, 12])
        XCTAssertEqual(p.duration, MediaTime(seconds: 14))
        XCTAssertTrue(SequenceMap(project: p).isGap(at: MediaTime(seconds: 1)))
        XCTAssertTrue(SequenceMap(project: p).isGap(at: MediaTime(seconds: 10)))
        XCTAssertFalse(SequenceMap(project: p).isGap(at: MediaTime(seconds: 3)))
        // In a gap, the clip under the playhead is the one after it.
        XCTAssertEqual(SequenceMap(project: p).entry(at: MediaTime(seconds: 10))?.clipID, ids[0])
    }

    func testDroppedOverAClipItGoesBesideItAndPushesTheRest() throws {
        var (p, ids) = try project()
        // The last (4 s) clip dropped at 1 s: its middle (3 s) is past the first clip's (1 s), so
        // it goes after it at 2 s, pushing the 3 s clip to 6 s.
        try PlaceClipCommand(clipID: ids[2], start: MediaTime(seconds: 1)).apply(to: &p)
        XCTAssertEqual(p.clips.map(\.id), [ids[0], ids[2], ids[1]])
        XCTAssertEqual(starts(p), [0, 2, 6])
        // Never before 0.
        try PlaceClipCommand(clipID: ids[1], start: MediaTime(seconds: -5)).apply(to: &p)
        XCTAssertEqual(starts(p).first, 0)
    }

    func testGapsTravelWithTheirClipAndSaveAsVersionTwo() throws {
        var (p, ids) = try project()
        try PlaceClipCommand(clipID: ids[1], start: MediaTime(seconds: 4)).apply(to: &p)
        XCTAssertEqual(starts(p), [0, 4, 7])
        // A split keeps the gap before the first half only.
        try SplitClipCommand(clipID: ids[1], sourceTime: MediaTime(seconds: 1)).apply(to: &p)
        XCTAssertEqual(starts(p), [0, 4, 5, 7])
        let data = try ProjectStore.encoder.encode(p)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\" : 2"))
        XCTAssertEqual(try ProjectStore.decoder.decode(Project.self, from: data), p)
        // Removing a clip takes its gap with it.
        try RemoveClipCommand(clipID: ids[1]).apply(to: &p)
        XCTAssertEqual(starts(p), [0, 2, 4])
    }
}
