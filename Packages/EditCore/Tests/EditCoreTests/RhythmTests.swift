import XCTest

@testable import EditCore

final class RhythmTests: XCTestCase {
    func testQuickClickAt120IsHalfASecondApartWithADownbeatEveryFour() {
        let guide = ClickGuide(bpm: 120)
        let clicks = guide.clicks(upTo: MediaTime(seconds: 4))
        XCTAssertEqual(clicks.count, 8)
        for (i, click) in clicks.enumerated() {
            XCTAssertEqual(click.time, MediaTime(seconds: Double(i) * 0.5))
            XCTAssertEqual(click.weight, i % 4 == 0 ? .accent : .beat)
        }
        XCTAssertEqual(guide.barDuration, MediaTime(seconds: 2))
    }

    func testEighthsAddQuietSubdivisionsAndTempoIsClamped() {
        let clicks = ClickGuide(bpm: 120, subdivision: .eighth).clicks(upTo: MediaTime(seconds: 1))
        XCTAssertEqual(clicks.map(\.time), [0, 0.25, 0.5, 0.75].map { MediaTime(seconds: $0) })
        XCTAssertEqual(clicks.map(\.weight), [.accent, .subdivision, .beat, .subdivision])
        XCTAssertEqual(ClickGuide(bpm: 900).bpm, 300)
        XCTAssertEqual(
            ClickGuide(bpm: 120, accentsDownbeat: false).clicks(upTo: MediaTime(seconds: 1))[0].weight, .beat)
    }

    func testTimeSignaturesSetTheBarAndItsAccents() throws {
        let waltz = ClickGuide(bpm: 120, meter: .threeFour).clicks(upTo: MediaTime(seconds: 3))
        XCTAssertEqual(waltz.map(\.weight), [.accent, .beat, .beat, .accent, .beat, .beat])
        XCTAssertEqual(ClickGuide(bpm: 120, meter: .threeFour).barDuration, MediaTime(seconds: 1.5))
        // 6/8 counts eighths in two groups of three, and ignores the eighth subdivision.
        let jig = ClickGuide(bpm: 180, meter: .sixEight, subdivision: .eighth).clicks(upTo: MediaTime(seconds: 2))
        XCTAssertEqual(jig.map(\.weight), [.accent, .subdivision, .subdivision, .beat, .subdivision, .subdivision])
        XCTAssertEqual(jig[1].time, MediaTime(seconds: 1.0 / 3))
        // A guide saved before meters (a count of beats) reads as 4/4.
        let old = #"{"bpm":100,"beatsPerBar":4,"subdivision":"quarter","accentsDownbeat":true}"#
        XCTAssertEqual(try JSONDecoder().decode(ClickGuide.self, from: Data(old.utf8)).meter, .fourFour)
        let three = #"{"bpm":100,"beatsPerBar":3}"#
        XCTAssertEqual(try JSONDecoder().decode(ClickGuide.self, from: Data(three.utf8)).meter, .threeFour)
    }

    func testTapTempoTakesTheMedianAndIgnoresAMissedBeat() {
        var capture = TapCapture()
        // Steady 0.5 s with a little jitter, one missed beat (1.0 s gap) and one rushed tap.
        for t in [10.0, 10.51, 11.0, 11.49, 12.5, 13.0, 13.38, 13.5, 14.01] { capture.tap(at: t) }
        XCTAssertEqual(capture.bpm ?? 0, 120, accuracy: 2)
        // Too few taps for a tempo.
        var two = TapCapture()
        two.tap(at: 0)
        two.tap(at: 0.5)
        XCTAssertNil(two.bpm)
    }

    func testALongPauseStartsOverAndBouncesAreDropped() {
        var capture = TapCapture()
        capture.tap(at: 1)
        capture.tap(at: 1.5)
        XCTAssertFalse(capture.tap(at: 1.52), "a bounce")
        capture.tap(at: 10)  // after a long pause: a new take
        capture.tap(at: 10.4)
        XCTAssertEqual(capture.times, [10, 10.4])
        XCTAssertEqual(capture.rhythm.map(\.time), [MediaTime.zero, MediaTime(seconds: 0.4)])
    }

    func testRhythmKeepsUnevenSpacingAndQuantizingIsReversible() {
        let taps = [0.0, 0.3, 0.52, 1.24].map { TapRhythm.Tap(time: MediaTime(seconds: $0)) }
        var rhythm = TapRhythm(mode: .rhythm, taps: taps, grid: ClickGuide(bpm: 120, subdivision: .eighth))
        XCTAssertEqual(rhythm.clicks(upTo: MediaTime(seconds: 10)).map(\.time), taps.map(\.time))
        rhythm.quantization = .grid
        XCTAssertEqual(rhythm.placedTaps.map(\.time.seconds), [0, 0.25, 0.5, 1.25])
        rhythm.quantization = .light
        XCTAssertEqual(rhythm.placedTaps[1].time.seconds, 0.275, accuracy: 1e-4)
        rhythm.quantization = .human
        XCTAssertEqual(rhythm.placedTaps, taps, "the original taps are kept")
    }

    func testARepeatedPatternLoopsByWholeBars() {
        let taps = [0.0, 0.75].map { TapRhythm.Tap(time: MediaTime(seconds: $0)) }
        var rhythm = TapRhythm(mode: .rhythm, taps: taps, grid: ClickGuide(bpm: 120))
        XCTAssertEqual(rhythm.clicks(upTo: MediaTime(seconds: 5)).count, 2, "plays once unless asked to repeat")
        rhythm.repeats = true
        XCTAssertEqual(rhythm.patternDuration, MediaTime(seconds: 2))
        XCTAssertEqual(rhythm.clicks(upTo: MediaTime(seconds: 5)).map(\.time.seconds), [0, 0.75, 2, 2.75, 4, 4.75])
    }

    func testOlderTracksAndSidecarsStillDecode() throws {
        let old = #"{"id":"\#(UUID().uuidString)","fileName":"a.m4a","duration":{"value":30,"timescale":1}}"#
        let track = try JSONDecoder().decode(AudioTrack.self, from: Data(old.utf8))
        XCTAssertEqual(track.kind, .myMusic)
        XCTAssertNil(track.reference)
        var project = Project(name: "Old")
        project.referenceAudio = track
        let note = try XCTUnwrap(MusicSyncNote(project: project))
        let data = try JSONEncoder().encode(note)
        // A note written before this feature lacks the new keys and still reads back.
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["referenceKind", "songTitle", "songArtist", "songSection"] { dict[key] = nil }
        let older = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertNil(try JSONDecoder().decode(MusicSyncNote.self, from: older).songTitle)
    }

    func testBillboardsSongGoesIntoTheHandoff() throws {
        var project = Project(name: "Song")
        let song = SongIdentity(
            title: "Midnight", artist: "The Reels", section: "chorus", tappedFrom: MediaTime(seconds: 42))
        var track = AudioTrack(fileName: "g.wav", duration: MediaTime(seconds: 60), offset: MediaTime(seconds: 2))
        track.reference = MusicReference(kind: .billboards, rhythm: TapRhythm(mode: .tempo), song: song)
        project.referenceAudio = track
        let note = try XCTUnwrap(MusicSyncNote(project: project))
        XCTAssertEqual(note.songTitle, "Midnight")
        XCTAssertEqual(note.songArtist, "The Reels")
        XCTAssertEqual(note.songStartSeconds, 40, accuracy: 1e-6, "tapped from 0:42, which is 2 s into the video")
        XCTAssertEqual(
            note.instruction, "In Instagram, add \u{201C}Midnight\u{201D} by The Reels and start it at 0:40.00.")
        // Without where the tapping began, it says where that spot falls in the video instead.
        project.referenceAudio?.reference?.song?.tappedFrom = nil
        XCTAssertTrue(try XCTUnwrap(MusicSyncNote(project: project)).instruction.contains("(chorus) comes in 0:02.00"))
    }

    func testQuickClickHandoffNamesTheFirstDownbeatInTheVideo() throws {
        var project = Project(name: "Click")
        var track = AudioTrack(fileName: "c.wav", duration: MediaTime(seconds: 60), offset: MediaTime(seconds: -0.5))
        track.reference = MusicReference(kind: .quickClick, click: ClickGuide(bpm: 120))
        project.referenceAudio = track
        // Beat one is 0.5 s before the video; bars are 2 s, so the next downbeat is 1.5 s in.
        XCTAssertTrue(try XCTUnwrap(MusicSyncNote(project: project)).instruction.contains("0:01.50 into the video"))
    }
}
