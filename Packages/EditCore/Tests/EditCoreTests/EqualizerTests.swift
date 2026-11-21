import XCTest

@testable import EditCore

final class EqualizerTests: XCTestCase {
    private let rate = 44_100.0

    func testFlatChangesNothing() {
        XCTAssertTrue(MasterEQ.flat.filters(sampleRate: rate).isEmpty)
        XCTAssertFalse(MasterEQ.flat.isActive)
        XCTAssertEqual(MasterEQ.flat.response(at: 1_000), 0)
    }

    func testEachBandShapesItsPartOfTheSpectrum() {
        var eq = MasterEQ.flat
        eq.lowCut = 100
        XCTAssertEqual(eq.response(at: 100), -3, accuracy: 0.1, "the corner is 3 dB down")
        XCTAssertLessThan(eq.response(at: 25), -20)
        XCTAssertEqual(eq.response(at: 5_000), 0, accuracy: 0.05)

        eq = .flat
        eq.lowGain = 6
        XCTAssertEqual(eq.response(at: 30), 6, accuracy: 0.3)
        XCTAssertEqual(eq.response(at: 5_000), 0, accuracy: 0.1)

        eq = .flat
        eq.highGain = -6
        XCTAssertEqual(eq.response(at: 18_000), -6, accuracy: 0.5)
        XCTAssertEqual(eq.response(at: 200), 0, accuracy: 0.1)

        eq = .flat
        eq.midFrequency = 2_500
        eq.midGain = -9
        eq.midWidth = 1
        XCTAssertEqual(eq.response(at: 2_500), -9, accuracy: 0.05)
        XCTAssertGreaterThan(eq.response(at: 2_500 / 4), -1.5, "two octaves away it's mostly gone")
        XCTAssertGreaterThan(eq.response(at: 2_500 * 4), -1.5)
    }

    func testOffKeepsTheSettingsButIsInactive() {
        var eq = MasterEQ.flat
        eq.midGain = 4
        XCTAssertTrue(eq.isActive)
        eq.isOn = false
        XCTAssertFalse(eq.isActive)
        XCTAssertEqual(eq.midGain, 4)
    }

    func testCommandClampsAndUndoes() throws {
        var project = Project(name: "EQ")
        var eq = MasterEQ.flat
        eq.midGain = 40
        eq.lowCut = 5
        var stack = UndoStack()
        try stack.perform(SetMasterEQCommand(eq: eq), on: &project)
        XCTAssertEqual(project.masterEQ.midGain, 12)
        XCTAssertEqual(project.masterEQ.lowCut, 20)
        _ = stack.undo(&project)
        XCTAssertEqual(project.masterEQ, .flat)
    }

    func testProjectKeepsItsEQAndOldFilesOpenFlat() throws {
        var project = Project(name: "EQ")
        project.masterEQ.highGain = 3
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data).masterEQ.highGain, 3)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["masterEQ"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: old).masterEQ, .flat)
    }
}
