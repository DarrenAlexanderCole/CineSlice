import XCTest

@testable import EditCore

final class AutomationTests: XCTestCase {
    /// Clips of the given lengths at the given static levels, plus 60 s of music at `music`.
    private func project(clips: [(seconds: Double, volume: Float)] = [(10, 1)], music: Float? = 0.8) -> Project {
        var p = Project(name: "Mix")
        let sources = clips.map {
            SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: $0.seconds), width: 1080, height: 1920)
        }
        try! AddClipsCommand(sources: sources).apply(to: &p)
        for (i, clip) in clips.enumerated() { p.clips[i].volume = clip.volume }
        if let music {
            var track = AudioTrack(fileName: "m.m4a", duration: MediaTime(seconds: 60))
            track.volume = music
            p.referenceAudio = track
        }
        return p
    }

    private func t(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    private func point(_ seconds: Double, _ value: Float) -> AutomationPoint {
        AutomationPoint(time: t(seconds), value: value)
    }

    /// Fader samples at 30 Hz from `from` to `to`, following `level`.
    private func samples(_ from: Double, _ to: Double, level: (Double) -> Float) -> [AutomationPoint] {
        stride(from: from, through: to, by: 1.0 / 30).map { point($0, level($0)) }
    }

    /// What the envelope plays at `seconds`, ramping linearly between breakpoints.
    private func level(_ envelope: [AutomationPoint], at seconds: Double) -> Float {
        let time = t(seconds)
        guard let i = envelope.lastIndex(where: { $0.time <= time }) else { return envelope[0].value }
        guard i + 1 < envelope.count else { return envelope[i].value }
        let a = envelope[i]
        let b = envelope[i + 1]
        let span = (b.time - a.time).seconds
        return span > 0 ? a.value + (b.value - a.value) * Float((time - a.time).seconds / span) : b.value
    }

    private func write(
        _ target: AutomationTarget, _ samples: [AutomationPoint], to p: inout Project
    ) throws {
        try WriteAutomationCommand(target: target, samples: samples).apply(to: &p)
    }

    // MARK: Recording

    func testRecordedPassKeepsOnlyTheShape() throws {
        // A steady fade from 100% to 20% over 2 s, then a hold: three points describe it.
        let raw = samples(1, 5) { s in s < 3 ? Float(1 - 0.4 * (s - 1)) : 0.2 }
        let pass = try XCTUnwrap(AutomationSegment(recorded: raw, sequenceDuration: t(10)))
        XCTAssertEqual(pass.points.count, 3)
        XCTAssertEqual(pass.start, raw.first?.time)
        XCTAssertEqual(pass.end, raw.last?.time)
        for sample in raw {
            XCTAssertEqual(pass.value(at: sample.time), sample.value, accuracy: AutomationLane.tolerance)
        }
    }

    func testRecordingClampsAndRejectsEmptyPasses() throws {
        let pass = try XCTUnwrap(
            AutomationSegment(
                recorded: [point(9, 1.4), point(-1, 0.5), point(12, -0.2)], sequenceDuration: t(10)))
        XCTAssertEqual(pass.points.map(\.time), [t(0), t(9), t(10)])
        XCTAssertEqual(pass.points.map(\.value), [0.5, 1, 0])

        XCTAssertNil(AutomationSegment(recorded: [point(2, 0.5)], sequenceDuration: t(10)))
        XCTAssertNil(AutomationSegment(recorded: [point(11, 0.5), point(12, 0.4)], sequenceDuration: t(10)))
        var p = project()
        XCTAssertThrowsError(try write(.music, [point(2, 0.5)], to: &p)) {
            XCTAssertEqual($0 as? EditError, .invalidRange)
        }
        var silent = project(music: nil)
        XCTAssertThrowsError(try write(.music, [point(1, 0.5), point(2, 0.5)], to: &silent))
    }

    func testPassInsideAnOlderPassSplitsIt() throws {
        var p = project()
        try write(.music, [point(1, 0.2), point(9, 1.0)], to: &p)
        try write(.music, [point(4, 0.5), point(5, 0.5)], to: &p)
        let segments = p.automation.music.segments
        XCTAssertEqual(segments.map(\.start), [t(1), t(4), t(5)])
        XCTAssertEqual(segments.map(\.end), [t(4), t(5), t(9)])
        // The old ramp is cut where it was, not reshaped.
        XCTAssertEqual(segments[0].value(at: t(4)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(segments[2].value(at: t(5)), 0.6, accuracy: 1e-6)
        XCTAssertEqual(segments[2].value(at: t(9)), 1.0, accuracy: 1e-6)
    }

    func testPassOverAnOlderPassReplacesIt() throws {
        var p = project()
        try write(.music, [point(3, 0.2), point(4, 0.2)], to: &p)
        try write(.music, [point(6, 0.3), point(7, 0.3)], to: &p)
        try write(.music, [point(2, 0.9), point(5, 0.9)], to: &p)
        XCTAssertEqual(p.automation.music.segments.map(\.start), [t(2), t(6)])
        XCTAssertTrue(p.lane(for: .clipAudio).isEmpty)
    }

    func testWriteAndClearAreUndoableAndNamed() throws {
        var p = project()
        var undo = UndoStack()
        try undo.perform(WriteAutomationCommand(target: .music, samples: [point(1, 0.2), point(2, 0.4)]), on: &p)
        try undo.perform(
            WriteAutomationCommand(target: .clipAudio, samples: [point(1, 0.2), point(2, 0.4)]), on: &p)
        XCTAssertEqual(p.automation.music.segments.count, 1)
        XCTAssertEqual(undo.undo(&p), "Record Clip Level")
        XCTAssertTrue(p.lane(for: .clipAudio).isEmpty)
        XCTAssertEqual(p.automation.music.segments.count, 1)

        try undo.perform(ClearAutomationCommand(target: .music), on: &p)
        XCTAssertTrue(p.automation.music.isEmpty)
        XCTAssertEqual(undo.undo(&p), "Clear Music Curve")
        XCTAssertEqual(p.automation.music.segments.count, 1)
    }

    // MARK: Envelope

    func testWithoutAutomationTheEnvelopeIsTheStaticLevels() {
        let p = project(clips: [(4, 1), (6, 0.5)], music: 0.8)
        XCTAssertEqual(p.levelEnvelope(for: .music), [point(0, 0.8), point(10, 0.8)])
        // Each clip's own level, as a step at the cut.
        XCTAssertEqual(
            p.levelEnvelope(for: .clipAudio), [point(0, 1), point(4, 1), point(4, 0.5), point(10, 0.5)])
        XCTAssertEqual(project(music: nil).levelEnvelope(for: .music), [])
        XCTAssertEqual(Project(name: "Empty").levelEnvelope(for: .clipAudio), [])
    }

    func testPassGlidesInAndOutOfTheStaticLevel() throws {
        var p = project(music: 0.8)
        try write(.music, [point(4, 0.8), point(5, 0.2), point(6, 0.2)], to: &p)
        let envelope = p.levelEnvelope(for: .music)
        let glide = AutomationLane.glide.seconds
        XCTAssertEqual(envelope.first, point(0, 0.8))
        XCTAssertEqual(envelope.last, point(10, 0.8))
        XCTAssertEqual(level(envelope, at: 3), 0.8, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 4.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 5.5), 0.2, accuracy: 1e-6)
        // After the pass ends the level eases back over `glide`, with no step.
        XCTAssertEqual(level(envelope, at: 6 + glide / 2), 0.5, accuracy: 1e-3)
        XCTAssertEqual(level(envelope, at: 6 + glide), 0.8, accuracy: 1e-6)
        XCTAssertFalse(zip(envelope, envelope.dropFirst()).contains { $0.time == $1.time })
    }

    func testChangingTheStaticLevelLaterLeavesNoJump() throws {
        var p = project(music: 0.8)
        try write(.music, [point(4, 0.8), point(6, 0.8)], to: &p)
        try SetMusicVolumeCommand(volume: 0.3).apply(to: &p)
        let envelope = p.levelEnvelope(for: .music)
        let glide = AutomationLane.glide.seconds
        XCTAssertEqual(level(envelope, at: 4 - glide), 0.3, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 4 - glide / 2), 0.55, accuracy: 1e-3)
        XCTAssertEqual(level(envelope, at: 5), 0.8, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 6 + glide), 0.3, accuracy: 1e-6)
        XCTAssertFalse(zip(envelope, envelope.dropFirst()).contains { $0.time == $1.time })
    }

    func testClipCurveOverridesEachClipsLevelOnlyWhereRecorded() throws {
        var p = project(clips: [(4, 1), (6, 0.5)])
        try write(.clipAudio, [point(3, 0.1), point(5, 0.1)], to: &p)
        let envelope = p.levelEnvelope(for: .clipAudio)
        XCTAssertEqual(level(envelope, at: 1), 1, accuracy: 1e-6)
        // Across the cut at 4 s the recorded level holds; the second clip's own level returns after.
        XCTAssertEqual(level(envelope, at: 4), 0.1, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 8), 0.5, accuracy: 1e-6)
    }

    // MARK: Clip curves

    func testClipPassIsSplitOntoTheClipsItPlaysOver() throws {
        var p = project(clips: [(4, 1), (6, 0.5)])
        try write(.clipAudio, [point(3, 0.1), point(5, 0.3)], to: &p)
        // Each clip holds its part in its own source time.
        let first = try XCTUnwrap(p.clips[0].levelCurve.segments.first)
        let second = try XCTUnwrap(p.clips[1].levelCurve.segments.first)
        XCTAssertEqual(p.clips.map(\.levelCurve.segments.count), [1, 1])
        XCTAssertEqual(first.points.map(\.time), [t(3), t(4)])
        XCTAssertEqual(second.points.map(\.time), [t(0), t(1)])
        XCTAssertEqual(first.value(at: t(4)), 0.2, accuracy: 1e-6)
        XCTAssertEqual(second.value(at: t(0)), 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.lane(for: .clipAudio).segments.map(\.start), [t(3), t(4)])
    }

    func testClipCurveTravelsWithItsClip() throws {
        var p = project(clips: [(4, 1), (6, 0.5)])
        try write(.clipAudio, [point(1, 0.1), point(2, 0.1)], to: &p)
        try MoveClipCommand(clipID: p.clips[0].id, toIndex: 1).apply(to: &p)
        // The first clip now starts at 6 s, and its dip went with it.
        let envelope = p.levelEnvelope(for: .clipAudio)
        XCTAssertEqual(level(envelope, at: 1.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 7.5), 0.1, accuracy: 1e-6)
    }

    func testClipCurveNeverGlidesIntoTheNextClip() throws {
        var p = project(clips: [(4, 1), (6, 0.5)])
        try write(.clipAudio, [point(3, 0.1), point(4, 0.1)], to: &p)
        let envelope = p.levelEnvelope(for: .clipAudio)
        // The next clip starts at its own level on its first frame.
        XCTAssertTrue(envelope.contains(point(4, 0.1)))
        XCTAssertTrue(envelope.contains(point(4, 0.5)))
        XCTAssertEqual(level(envelope, at: 4.05), 0.5, accuracy: 1e-6)
        // A pass just inside a clip eases back towards that clip's level and steps at the cut.
        var q = project(clips: [(4, 1), (6, 0.5)])
        try write(.clipAudio, [point(5, 0.1), point(5.95, 0.1)], to: &q)
        let eased = q.levelEnvelope(for: .clipAudio)
        XCTAssertEqual(level(eased, at: 4 - AutomationLane.glide.seconds), 1, accuracy: 1e-6)
        XCTAssertEqual(level(eased, at: 4.01), 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(level(eased, at: 6.05), 0.1)
    }

    func testTrimHidesAndRestoresTheClipCurve() throws {
        var p = project(clips: [(10, 1)])
        try write(.clipAudio, [point(6, 0.2), point(8, 0.2)], to: &p)
        let id = p.clips[0].id
        try TrimClipCommand(clipID: id, sourceRange: MediaTimeRange(start: t(4), duration: t(3))).apply(to: &p)
        // Source 6–7 s now plays at 2–3 s; the rest of the pass is out of the clip.
        XCTAssertEqual(p.lane(for: .clipAudio).segments.map(\.start), [t(2)])
        XCTAssertEqual(p.lane(for: .clipAudio).segments.map(\.end), [t(3)])
        try TrimClipCommand(clipID: id, sourceRange: MediaTimeRange(start: .zero, duration: t(10))).apply(to: &p)
        XCTAssertEqual(p.lane(for: .clipAudio).segments.map(\.end), [t(8)])
    }

    func testClearingOneClipLeavesTheOthers() throws {
        var p = project(clips: [(4, 1), (6, 0.5)])
        var undo = UndoStack()
        try write(.clipAudio, [point(3, 0.1), point(5, 0.3)], to: &p)
        try undo.perform(ClearAutomationCommand(target: .clipAudio, clipID: p.clips[1].id), on: &p)
        XCTAssertFalse(p.clips[0].levelCurve.isEmpty)
        XCTAssertTrue(p.clips[1].levelCurve.isEmpty)
        try undo.perform(ClearAutomationCommand(target: .clipAudio), on: &p)
        XCTAssertTrue(p.lane(for: .clipAudio).isEmpty)
        XCTAssertEqual(undo.undo(&p), "Clear Clip Curves")
        XCTAssertFalse(p.clips[0].levelCurve.isEmpty)
    }

    func testOldProjectWideClipCurveMovesOntoTheClips() throws {
        var p = project(clips: [(4, 1), (6, 0.5)])
        var json = try JSONSerialization.jsonObject(with: ProjectStore.encoder.encode(p)) as! [String: Any]
        let pass = AutomationLane(segments: [AutomationSegment(points: [point(3, 0.1), point(5, 0.3)])])
        let old = try JSONSerialization.jsonObject(
            with: ProjectStore.encoder.encode(["clipAudio": pass, "music": AutomationLane()]))
        json["automation"] = old
        p = try ProjectStore.decoder.decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(p.lane(for: .clipAudio).segments.map(\.start), [t(3), t(4)])
        XCTAssertEqual(p.clips[1].levelCurve.segments.first?.points.last, point(1, 0.3))
    }

    func testPassesThatTouchStepFromOneToTheNext() throws {
        var p = project()
        try write(.music, [point(2, 0.2), point(4, 0.2)], to: &p)
        try write(.music, [point(4, 0.6), point(6, 0.6)], to: &p)
        let envelope = p.levelEnvelope(for: .music)
        XCTAssertTrue(envelope.contains(point(4, 0.2)))
        XCTAssertTrue(envelope.contains(point(4, 0.6)))
        XCTAssertEqual(level(envelope, at: 3), 0.2, accuracy: 1e-6)
        XCTAssertEqual(level(envelope, at: 5), 0.6, accuracy: 1e-6)
    }

    func testCurvesPastTheEndOfAShortenedSequenceAreIgnored() throws {
        var p = project(clips: [(10, 1)])
        try write(.music, [point(8, 0.1), point(10, 0.1)], to: &p)
        try TrimClipCommand(
            clipID: p.clips[0].id, sourceRange: MediaTimeRange(start: .zero, duration: t(5))
        ).apply(to: &p)
        let envelope = p.levelEnvelope(for: .music)
        XCTAssertEqual(envelope, [point(0, 0.8), point(5, 0.8)])
    }

    // MARK: Persistence

    func testCurvesPersist() throws {
        var p = project()
        try write(.music, samples(1, 3) { Float($0 / 3) }, to: &p)
        try write(.clipAudio, [point(2, 0.3), point(4, 0.7)], to: &p)
        let data = try ProjectStore.encoder.encode(p)
        let reopened = try ProjectStore.decoder.decode(Project.self, from: data)
        XCTAssertEqual(reopened.automation, p.automation)
        XCTAssertEqual(reopened.clips, p.clips)
        XCTAssertEqual(reopened.levelEnvelope(for: .music), p.levelEnvelope(for: .music))
    }
}
