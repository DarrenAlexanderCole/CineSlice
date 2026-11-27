import XCTest

@testable import EditCore

final class BinTests: XCTestCase {
    private func take() -> SourceAsset {
        SourceAsset(fileName: "t.mov", duration: MediaTime(seconds: 4), width: 1080, height: 1920, isTake: true)
    }

    func testTakesGoInTheBinNotTheSequence() throws {
        var p = Project(name: "Bin")
        let source = take()
        try AddToBinCommand(sources: [source]).apply(to: &p)
        XCTAssertEqual(p.sources.map(\.id), [source.id])
        XCTAssertTrue(p.clips.isEmpty)
        // Adding it again changes nothing.
        try AddToBinCommand(sources: [source]).apply(to: &p)
        XCTAssertEqual(p.sources.count, 1)
    }

    func testFromTheBinToTheSequenceKeepsOneSource() throws {
        var p = Project(name: "Bin")
        let source = take()
        try AddToBinCommand(sources: [source]).apply(to: &p)
        try AddClipsCommand(sources: [source]).apply(to: &p)
        try AddClipsCommand(sources: [source]).apply(to: &p)
        XCTAssertEqual(p.sources.count, 1)
        XCTAssertEqual(p.clips.map(\.sourceID), [source.id, source.id])
    }

    func testTakeMarkSurvivesSavingAndIsLeftOutOtherwise() throws {
        var p = Project(name: "Bin")
        try AddToBinCommand(sources: [take()]).apply(to: &p)
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        XCTAssertTrue(back.sources[0].isTake)
        let plain = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 1), width: 2, height: 2)
        let json = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
        XCTAssertFalse(json.contains("isTake"))
        XCTAssertEqual(try JSONDecoder().decode(SourceAsset.self, from: Data(json.utf8)), plain)
    }

    func testSoundsWaitInTheBinAndSurviveSaving() throws {
        var p = Project(name: "Bin")
        let sound = BinSound(
            fileName: "s.m4a", originalFilename: "Take 1", duration: MediaTime(seconds: 3), isTake: true)
        try AddToBinCommand(sounds: [sound]).apply(to: &p)
        XCTAssertTrue(p.soundTracks.isEmpty)
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.binSounds, [sound])
        // An empty bin isn't written, so older builds read the file unchanged.
        let empty = String(data: try JSONEncoder().encode(Project(name: "E")), encoding: .utf8)!
        XCTAssertFalse(empty.contains("binSounds"))
    }

    func testRemovingTakesItOffTheTimelineToo() throws {
        var p = Project(name: "Bin")
        let keep = SourceAsset(fileName: "k.mov", duration: MediaTime(seconds: 2), width: 2, height: 2)
        let gone = take()
        try AddClipsCommand(sources: [keep, gone, gone]).apply(to: &p)
        let sound = BinSound(fileName: "s.m4a", duration: MediaTime(seconds: 3))
        try AddToBinCommand(sounds: [sound]).apply(to: &p)
        try AddSoundCommand(clip: SoundClip(fileName: "s.m4a", fileDuration: sound.duration, start: .zero))
            .apply(to: &p)
        XCTAssertEqual(p.binUses(of: gone.id), 2)
        XCTAssertEqual(p.binUses(of: sound.id), 1)
        try RemoveFromBinCommand(ids: [gone.id, sound.id]).apply(to: &p)
        XCTAssertEqual(p.sources.map(\.id), [keep.id])
        XCTAssertEqual(p.clips.map(\.sourceID), [keep.id])
        XCTAssertTrue(p.binSounds.isEmpty)
        XCTAssertTrue(p.soundTracks.allSatisfy(\.clips.isEmpty))
        XCTAssertThrowsError(try RemoveFromBinCommand(ids: [UUID()]).apply(to: &p))
    }

    func testRenameNamesThePictureOrTheSoundAndItsLaneCopies() throws {
        var p = Project(name: "Bin")
        let source = take()
        let sound = BinSound(fileName: "s.m4a", duration: MediaTime(seconds: 3))
        try AddToBinCommand(sources: [source], sounds: [sound]).apply(to: &p)
        try AddSoundCommand(clip: SoundClip(fileName: "s.m4a", fileDuration: sound.duration, start: .zero))
            .apply(to: &p)
        try RenameMediaCommand(id: source.id, name: "  Beach  ").apply(to: &p)
        try RenameMediaCommand(id: sound.id, name: "Waves").apply(to: &p)
        XCTAssertEqual(p.sources[0].originalFilename, "Beach")
        XCTAssertEqual(p.binSounds[0].originalFilename, "Waves")
        XCTAssertEqual(p.soundTracks.first?.clips.first?.originalFilename, "Waves")
        XCTAssertThrowsError(try RenameMediaCommand(id: source.id, name: "   ").apply(to: &p))
    }
}
