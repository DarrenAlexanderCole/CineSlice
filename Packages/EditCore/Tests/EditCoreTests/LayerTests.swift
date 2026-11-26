import XCTest

@testable import EditCore

final class LayerTests: XCTestCase {
    private func source(_ seconds: Double) -> SourceAsset {
        SourceAsset(fileName: "b.mov", duration: MediaTime(seconds: seconds), width: 1080, height: 1920)
    }

    private func starts(_ p: Project) -> [Double] {
        SequenceMap(project: p).entries.map(\.compositionRange.start.seconds)
    }

    func testAddingGoesOnTheLowestLaneClearAtThePlayhead() throws {
        var p = Project(name: "Add")
        // An empty project: onto the sequence, at the playhead.
        let first = AddClipsAtCommand(sources: [source(2), source(2)], start: .zero)
        try first.apply(to: &p)
        XCTAssertEqual(first.lane(in: p), 0)
        XCTAssertEqual(starts(p), [0, 2])
        // Over the sequence: the lane above, nothing pushed.
        let over = AddClipsAtCommand(sources: [source(2)], start: MediaTime(seconds: 1))
        try over.apply(to: &p)
        XCTAssertEqual(over.lane(in: p), 1)
        XCTAssertEqual(starts(p), [0, 2])
        // After the sequence's end, with a gap: back on the sequence.
        let after = AddClipsAtCommand(sources: [source(1)], start: MediaTime(seconds: 6))
        try after.apply(to: &p)
        XCTAssertEqual(after.lane(in: p), 0)
        XCTAssertEqual(starts(p), [0, 2, 6])
        // Into a gap long enough: the sequence again, the rest where they were.
        let gap = AddClipsAtCommand(sources: [source(1.5)], start: MediaTime(seconds: 4))
        try gap.apply(to: &p)
        XCTAssertEqual(gap.lane(in: p), 0)
        XCTAssertEqual(starts(p), [0, 2, 4, 6])
        // Over everything on every lane (V2 already holds one there): refused.
        for _ in 2..<Project.videoLanes {
            try AddClipsAtCommand(sources: [source(2)], start: MediaTime(seconds: 0.5)).apply(to: &p)
        }
        XCTAssertThrowsError(try AddClipsAtCommand(sources: [source(2)], start: MediaTime(seconds: 0.5)).apply(to: &p))
        {
            XCTAssertEqual($0 as? EditError, .noRoom)
        }
    }

    func testClipsMoveBetweenAnyLanesAndNothingElseMoves() throws {
        var p = Project(name: "Move")
        let base = AddClipsAtCommand(sources: [source(2), source(2), source(2)], start: .zero)
        try base.apply(to: &p)
        let middle = base.clipIDs[1]
        // The middle clip up to V3: a gap where it was, the last clip still at 4 s.
        try MoveVideoClipCommand(clipID: middle, lane: 2, start: MediaTime(seconds: 1)).apply(to: &p)
        XCTAssertEqual(starts(p), [0, 4])
        XCTAssertEqual(p.videoLane(ofClip: middle), 2)
        XCTAssertEqual(p.videoLayers.count, 2, "V2 is kept, empty, under it")
        // Back down into the sequence where it's clear.
        XCTAssertFalse(MoveVideoClipCommand.canMove(middle, toLane: 0, start: MediaTime(seconds: 1), in: p))
        try MoveVideoClipCommand(clipID: middle, lane: 0, start: MediaTime(seconds: 2)).apply(to: &p)
        XCTAssertEqual(starts(p), [0, 2, 4])
        XCTAssertTrue(p.videoLayers.isEmpty, "empty lanes at the top aren't kept")
        // A clip played at another speed stays on the sequence.
        try SetSpeedForTest.apply(middle, to: &p)
        XCTAssertFalse(MoveVideoClipCommand.canMove(middle, toLane: 1, start: .zero, in: p))
    }

    func testRemovingInLightboxLeavesAGap() throws {
        var p = Project(name: "Remove")
        let base = AddClipsAtCommand(sources: [source(2), source(2)], start: .zero)
        try base.apply(to: &p)
        try RemoveClipCommand(clipID: base.clipIDs[0], leavesGap: true).apply(to: &p)
        XCTAssertEqual(starts(p), [2])
    }

    func testSplittingAndRemovingStackedClips() throws {
        var p = Project(name: "Split")
        try AddClipsAtCommand(sources: [source(4)], start: .zero).apply(to: &p)
        let stacked = AddClipsAtCommand(sources: [source(2)], start: .zero)
        try stacked.apply(to: &p)
        let id = stacked.clipIDs[0]
        let split = SplitLayerClipCommand(clipID: id, time: MediaTime(seconds: 0.5))
        try split.apply(to: &p)
        let second = try XCTUnwrap(p.layerClip(id: split.newClipID))
        XCTAssertEqual(second.start.seconds, 0.5)
        XCTAssertEqual(second.clip.sourceRange.start.seconds, 0.5, accuracy: 1e-9)
        for id in [id, split.newClipID] { try RemoveLayerClipCommand(clipID: id).apply(to: &p) }
        XCTAssertTrue(p.videoLayers.isEmpty)
    }

    func testStackedLanesSaveAsVersionTwo() throws {
        var p = Project(name: "Save")
        try AddClipsAtCommand(sources: [source(2)], start: .zero).apply(to: &p)
        try AddClipsAtCommand(sources: [source(2)], start: .zero).apply(to: &p)
        XCTAssertEqual(p.minimumSchemaVersion, 2)
        let decoded = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(decoded.videoLayers, p.videoLayers)
        p.videoLayers = []
        XCTAssertEqual(p.minimumSchemaVersion, 1)
    }
}

/// Sets a clip's speed directly; the app has no speed edit in LIGHTBOX.
private enum SetSpeedForTest {
    static func apply(_ id: UUID, to p: inout Project) throws {
        let i = try XCTUnwrap(p.index(ofClip: id))
        p.clips[i].speed = 2
    }
}
