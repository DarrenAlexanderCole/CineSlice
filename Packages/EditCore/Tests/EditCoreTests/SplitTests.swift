import XCTest

@testable import EditCore

final class SplitTests: XCTestCase {
    private func project() -> Project {
        var p = Project(name: "Split")
        let a = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 10), width: 1920, height: 1080)
        let b = SourceAsset(fileName: "b.mov", duration: MediaTime(seconds: 4), width: 1080, height: 1920)
        try! AddClipsCommand(sources: [a, b]).apply(to: &p)
        try! TrimClipCommand(
            clipID: p.clips[0].id, sourceRange: MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 8))
        ).apply(to: &p)
        return p
    }

    func testSplitCutsAtTheSourceTimeAndKeepsEverythingElse() throws {
        var p = project()
        p.clips[0].framing = .fit
        p.clips[0].crop = Crop(x: 0.1, y: 0.2, size: 0.6)
        p.clips[0].volume = 0.4
        p.clips[0].balance = SoundBalance(voice: 0.2, scene: 1)
        let original = p.clips[0]
        let after = p.clips[1].id
        let mapBefore = SequenceMap(project: p)

        let newID = UUID()
        try SplitClipCommand(clipID: original.id, sourceTime: MediaTime(seconds: 5), newClipID: newID).apply(to: &p)

        XCTAssertEqual(p.clips.map(\.id), [original.id, newID, after])
        XCTAssertEqual(p.clips[0].sourceRange, MediaTimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 5)))
        XCTAssertEqual(p.clips[1].sourceRange, MediaTimeRange(start: MediaTime(seconds: 5), end: MediaTime(seconds: 8)))
        for half in p.clips[0...1] {
            XCTAssertEqual(half.sourceID, original.sourceID)
            XCTAssertEqual(half.framing, .fit)
            XCTAssertEqual(half.crop, original.crop)
            XCTAssertEqual(half.volume, 0.4)
            XCTAssertEqual(half.balance, original.balance)
            XCTAssertEqual(half.levelCurve, original.levelCurve)
        }
        // Nothing moves: same length, the next clip starts where it did.
        let map = SequenceMap(project: p)
        XCTAssertEqual(map.duration, mapBefore.duration)
        XCTAssertEqual(map.compositionStart(of: after), mapBefore.compositionStart(of: after))
        XCTAssertEqual(map.compositionStart(of: newID), MediaTime(seconds: 3))
    }

    func testSplitAtDoubleSpeedKeepsTheLength() throws {
        var p = project()
        p.clips[0].speed = 2
        let before = SequenceMap(project: p).duration
        try SplitClipCommand(clipID: p.clips[0].id, sourceTime: MediaTime(seconds: 4)).apply(to: &p)
        XCTAssertEqual(SequenceMap(project: p).duration, before)
        XCTAssertEqual(p.clips[0].compositionDuration, MediaTime(seconds: 1))
        XCTAssertEqual(p.clips[1].compositionDuration, MediaTime(seconds: 2))
    }

    func testTooCloseToAnEdgeIsRefusedAndChangesNothing() {
        var p = project()
        let clip = p.clips[0]
        let nearStart = clip.sourceRange.start + MediaTime(value: 1, timescale: 600)
        XCTAssertFalse(SplitClipCommand.canSplit(clip, at: nearStart))
        XCTAssertFalse(SplitClipCommand.canSplit(clip, at: clip.sourceRange.end))
        XCTAssertFalse(SplitClipCommand.canSplit(clip, at: MediaTime(seconds: 9)))  // past Out
        XCTAssertTrue(SplitClipCommand.canSplit(clip, at: clip.sourceRange.start + minimumClipDuration))
        let before = p
        XCTAssertThrowsError(try SplitClipCommand(clipID: clip.id, sourceTime: nearStart).apply(to: &p))
        XCTAssertEqual(p, before)
    }

    func testSplitIsOneUndoStep() throws {
        var p = project()
        let before = p
        var undo = UndoStack()
        try undo.perform(SplitClipCommand(clipID: p.clips[0].id, sourceTime: MediaTime(seconds: 5)), on: &p)
        XCTAssertEqual(p.clips.count, 3)
        XCTAssertEqual(undo.undo(&p), "Split Clip")
        XCTAssertEqual(p, before)
    }
}
