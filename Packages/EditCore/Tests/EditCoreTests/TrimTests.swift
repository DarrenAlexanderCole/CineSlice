import XCTest

@testable import EditCore

final class TrimTests: XCTestCase {
    private func source(_ seconds: Double) -> SourceAsset {
        SourceAsset(fileName: "b.mov", duration: MediaTime(seconds: seconds), width: 1080, height: 1920)
    }

    private func t(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    private func ranges(_ p: Project) -> [MediaTimeRange] {
        SequenceMap(project: p).entries.map(\.compositionRange)
    }

    /// Three 2 s clips end to end: 0–2, 2–4, 4–6.
    private func sequence() throws -> Project {
        var p = Project(name: "Trim")
        try AddClipsAtCommand(sources: [source(2), source(2), source(2)], start: .zero).apply(to: &p)
        return p
    }

    func testTrimmingAClipsStartLeavesAGapAndTheRestInPlace() throws {
        var p = try sequence()
        let middle = p.clips[1].id
        try TrimAtCommand(target: .clip(middle), edge: .start, time: t(2.5)).apply(to: &p)
        XCTAssertEqual(
            ranges(p),
            [
                MediaTimeRange(start: t(0), end: t(2)), MediaTimeRange(start: t(2.5), end: t(4)),
                MediaTimeRange(start: t(4), end: t(6)),
            ])
        XCTAssertEqual(p.clips[1].sourceRange, MediaTimeRange(start: t(0.5), end: t(2)))
        XCTAssertEqual(p.clips[1].gap, t(0.5))
    }

    func testTrimmingAClipsEndLeavesAGapBeforeTheNext() throws {
        var p = try sequence()
        try TrimAtCommand(target: .clip(p.clips[0].id), edge: .end, time: t(1.5)).apply(to: &p)
        XCTAssertEqual(ranges(p).map(\.start), [t(0), t(2), t(4)])
        XCTAssertEqual(p.clips[0].sourceRange, MediaTimeRange(start: t(0), end: t(1.5)))
        XCTAssertEqual(p.clips[1].gap, t(0.5))
    }

    func testTrimmingASpedUpClipCutsAtTheSourceTimeUnderThePlayhead() throws {
        var p = try sequence()
        // Twice as fast: 4 s of source plays in 0–2.
        p.clips[0].sourceRange = MediaTimeRange(start: t(0), end: t(4))
        p.sources[0].duration = t(4)
        p.clips[0].speed = 2
        try TrimAtCommand(target: .clip(p.clips[0].id), edge: .start, time: t(1)).apply(to: &p)
        XCTAssertEqual(p.clips[0].sourceRange, MediaTimeRange(start: t(2), end: t(4)))
        XCTAssertEqual(ranges(p)[0], MediaTimeRange(start: t(1), end: t(2)))
    }

    func testTrimIsRefusedOutsideTheClipOrWhenTooLittleIsKept() throws {
        var p = try sequence()
        let first = p.clips[0].id
        // The playhead in another clip.
        XCTAssertFalse(TrimAtCommand.canTrim(.clip(first), edge: .start, at: t(3), in: p))
        // At the clip's own ends nothing comes off.
        XCTAssertFalse(TrimAtCommand.canTrim(.clip(first), edge: .start, at: t(0), in: p))
        XCTAssertFalse(TrimAtCommand.canTrim(.clip(first), edge: .end, at: t(2), in: p))
        // A frame from the end: the start trim would keep too little; the end trim is fine.
        XCTAssertFalse(TrimAtCommand.canTrim(.clip(first), edge: .start, at: t(1.99), in: p))
        XCTAssertTrue(TrimAtCommand.canTrim(.clip(first), edge: .end, at: t(1.99), in: p))
        XCTAssertThrowsError(try TrimAtCommand(target: .clip(first), edge: .start, time: t(1.99)).apply(to: &p))
        XCTAssertThrowsError(try TrimAtCommand(target: .clip(UUID()), edge: .start, time: t(1)).apply(to: &p)) {
            XCTAssertEqual($0 as? EditError, .clipNotFound)
        }
    }

    func testTrimmingAStackedClipKeepsItsPictureInPlace() throws {
        var p = try sequence()
        let over = AddClipsAtCommand(sources: [source(3)], start: t(1))
        try over.apply(to: &p)
        let id = over.clipIDs[0]
        try TrimAtCommand(target: .layerClip(id), edge: .start, time: t(2)).apply(to: &p)
        XCTAssertEqual(p.layerClip(id: id)?.timelineRange, MediaTimeRange(start: t(2), end: t(4)))
        XCTAssertEqual(p.layerClip(id: id)?.clip.sourceRange, MediaTimeRange(start: t(1), end: t(3)))
        try TrimAtCommand(target: .layerClip(id), edge: .end, time: t(3)).apply(to: &p)
        XCTAssertEqual(p.layerClip(id: id)?.clip.sourceRange, MediaTimeRange(start: t(1), end: t(2)))
    }

    func testTrimmingASoundKeepsItsFadesToWhatIsLeft() throws {
        var p = Project(name: "Sound")
        let id = UUID()
        let clip = SoundClip(
            id: id, fileName: "s.m4a", fileDuration: t(4), start: t(1), fadeIn: t(1), fadeOut: t(1))
        try AddSoundCommand(clip: clip).apply(to: &p)
        try TrimAtCommand(target: .sound(id), edge: .end, time: t(2.5)).apply(to: &p)
        var trimmed = try XCTUnwrap(p.sound(id: id))
        XCTAssertEqual(trimmed.timelineRange, MediaTimeRange(start: t(1), end: t(2.5)))
        XCTAssertEqual(trimmed.fadeIn, t(1))
        XCTAssertEqual(trimmed.fadeOut, t(0.5))
        try TrimAtCommand(target: .sound(id), edge: .start, time: t(2)).apply(to: &p)
        trimmed = try XCTUnwrap(p.sound(id: id))
        XCTAssertEqual(trimmed.timelineRange, MediaTimeRange(start: t(2), end: t(2.5)))
        XCTAssertEqual(trimmed.sourceRange, MediaTimeRange(start: t(1), end: t(1.5)))
        XCTAssertEqual(trimmed.fadeIn + trimmed.fadeOut, t(0.5))
    }
}
