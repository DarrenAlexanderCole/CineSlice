import XCTest

@testable import EditCore

final class FadeTests: XCTestCase {
    private func t(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    /// Two 4 s clips at the given levels, and a 60 s song at 0.5.
    private func project(_ levels: [Float] = [1, 1]) -> Project {
        var p = Project(name: "Fades")
        let sources = levels.map { _ in
            SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 4), width: 1080, height: 1920)
        }
        try! AddClipsCommand(sources: sources).apply(to: &p)
        for (i, level) in levels.enumerated() { p.clips[i].volume = level }
        p.referenceAudio = AudioTrack(fileName: "m.m4a", duration: t(60), volume: 0.5)
        return p
    }

    /// The envelope's level at `seconds`, on the right of any step there.
    private func level(_ envelope: [AutomationPoint], at seconds: Double) -> Float {
        let time = t(seconds)
        for (a, b) in zip(envelope, envelope.dropFirst()) where b.time > a.time && a.time <= time && time < b.time {
            let f = Float((time - a.time).seconds / (b.time - a.time).seconds)
            return a.value + (b.value - a.value) * f
        }
        return envelope.last?.value ?? 0
    }

    func testClipFadesRiseFromAndFallToSilenceAtItsEnds() throws {
        var p = project([1, 0.6])
        try SetClipFadesCommand(clipID: p.clips[0].id, fadeIn: t(1), fadeOut: t(2)).apply(to: &p)
        let envelope = p.levelEnvelope(for: .clipAudio)
        XCTAssertEqual(level(envelope, at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(level(envelope, at: 0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(level(envelope, at: 1.5), 1, accuracy: 0.001)
        XCTAssertEqual(level(envelope, at: 3), 0.5, accuracy: 0.01)
        // The next clip, unfaded, starts at its own level straight after the cut.
        XCTAssertEqual(level(envelope, at: 4), 0.6, accuracy: 0.001)
        XCTAssertEqual(envelope.last { $0.time == t(4) }?.value ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(envelope.first { $0.time == t(4) }?.value ?? -1, 0, accuracy: 0.001)
    }

    func testFadeOverARecordedRampFollowsTheirProduct() throws {
        var p = project()
        // Clip level ramps 0 → 1 over the first clip, while it fades in over the same 4 s.
        p.writeClipLevel(
            AutomationSegment(points: [AutomationPoint(time: t(0), value: 0), AutomationPoint(time: t(4), value: 1)]))
        try SetClipFadesCommand(clipID: p.clips[0].id, fadeIn: t(4), fadeOut: .zero).apply(to: &p)
        let envelope = p.levelEnvelope(for: .clipAudio)
        // (2/4)·(2/4): a curve, followed closely enough by the pieces.
        XCTAssertEqual(level(envelope, at: 2), 0.25, accuracy: 0.03)
    }

    func testMusicFadesWhereItIsHeardNotPastTheSequence() throws {
        var p = project()
        try SetMusicFadesCommand(fadeIn: t(2), fadeOut: t(2)).apply(to: &p)
        let envelope = p.levelEnvelope(for: .music)
        // The song runs on to 60 s, but the sequence ends at 8 s: the fade out ends there.
        XCTAssertEqual(level(envelope, at: 1), 0.25, accuracy: 0.01)
        XCTAssertEqual(level(envelope, at: 4), 0.5, accuracy: 0.001)
        XCTAssertEqual(level(envelope, at: 7), 0.25, accuracy: 0.01)
        XCTAssertEqual(envelope.last?.time, t(8))
        XCTAssertEqual(envelope.last?.value ?? -1, 0, accuracy: 0.001)
    }

    func testFadesAreKeptToTheClipAndTravelWithASplit() throws {
        var p = project()
        let id = p.clips[0].id
        try SetClipFadesCommand(clipID: id, fadeIn: t(3), fadeOut: t(3)).apply(to: &p)
        XCTAssertEqual(p.clips[0].fadeIn, t(3))
        XCTAssertEqual(p.clips[0].fadeOut, t(1))
        let newID = UUID()
        try SplitClipCommand(clipID: id, sourceTime: t(2), newClipID: newID).apply(to: &p)
        XCTAssertEqual(p.clips[0].fadeIn, t(3))
        XCTAssertEqual(p.clips[0].fadeOut, .zero)
        XCTAssertEqual(p.clips[1].fadeIn, .zero)
        XCTAssertEqual(p.clips[1].fadeOut, t(1))
    }

    func testFadesSurviveSavingAndAreLeftOutWhenNone() throws {
        var p = project()
        let plain = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        XCTAssertFalse(plain.contains("fadeIn"))
        try SetClipFadesCommand(clipID: p.clips[1].id, fadeIn: t(0.5), fadeOut: .zero).apply(to: &p)
        try SetMusicFadesCommand(fadeIn: .zero, fadeOut: t(1.5)).apply(to: &p)
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.clips[1].fadeIn, t(0.5))
        XCTAssertEqual(back.referenceAudio?.fadeOut, t(1.5))
        // Old builds can still open it: they just don't hear the fades.
        XCTAssertEqual(back.minimumSchemaVersion, 1)
    }

    func testNoFadesLeavesTheEnvelopeAlone() {
        let p = project([1, 0.3])
        let envelope = p.levelEnvelope(for: .clipAudio)
        XCTAssertEqual(Project.applyingFades(envelope, regions: []), envelope)
        XCTAssertEqual(level(envelope, at: 5), 0.3, accuracy: 0.001)
    }
}
