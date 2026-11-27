import XCTest

@testable import EditCore

final class LookTests: XCTestCase {
    func testALookStaysOnTheTakeAndComesOff() throws {
        var p = Project(name: "Looks")
        let look = Look(id: "builtin:koda", name: "KODA", intensity: 1.4)
        XCTAssertEqual(look.intensity, 1)
        let source = SourceAsset(
            fileName: "t.mov", duration: MediaTime(seconds: 2), width: 2, height: 2, isTake: true, look: look)
        try AddToBinCommand(sources: [source]).apply(to: &p)
        XCTAssertTrue(p.usesLooks)
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.sources[0].look, look)
        try SetSourceLookCommand(sourceID: source.id, look: nil).apply(to: &p)
        XCTAssertNil(p.sources[0].look)
        XCTAssertFalse(p.usesLooks)
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"look\""))
        XCTAssertThrowsError(try SetSourceLookCommand(sourceID: UUID(), look: look).apply(to: &p))
    }
}
