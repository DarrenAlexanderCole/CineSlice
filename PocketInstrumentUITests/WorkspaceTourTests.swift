import XCTest

/// Walks one project through Arrange → Mix → Trim → Release with the demo media and
/// attaches a screenshot of each state. It checks that the controls exist and respond;
/// whether the layout looks right is judged from the screenshots.
final class WorkspaceTourTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTourOfStates() {
        button("New").tap()
        button("Demo clips").tap()
        XCTAssertTrue(button("Mix").waitForExistence(timeout: 60), "demo clips never arrived")
        sleep(2)
        shot("1 Arrange, no music")

        button("Mix").tap()
        button("Demo click track").tap()
        let lane = app.otherElements["Music position"]
        XCTAssertTrue(
            lane.waitForExistence(timeout: 30) || app.descendants(matching: .any)["Music position"].exists,
            "music lane never appeared")
        sleep(2)
        shot("2 Mix with click track")

        button("Music 10 milliseconds later").tap()
        button("Music one frame earlier").tap()
        shot("3 Mix after nudges")

        button("Arrange").tap()
        sleep(1)
        button("Loop region").tap()  // first tap: loops the selected clip
        sleep(1)
        shot("4 Arrange with waveform and loop")

        button("Loop region").press(forDuration: 1.0)
        XCTAssertTrue(button("Loop In at playhead").waitForExistence(timeout: 5))
        shot("5 Loop menu")
        button("Loop whole sequence").tap()

        button("Trim").tap()
        sleep(2)
        shot("6 Trim with music strip")

        button("Arrange").tap()
        button("Export").tap()
        XCTAssertTrue(button("Render video").waitForExistence(timeout: 5))
        shot("7 Release")
        app.swipeUp()
        sleep(1)
        shot("8 Release, scrolled")

        button("Render video").tap()
        XCTAssertTrue(button("Share sync file (.json)").waitForExistence(timeout: 120), "render didn't finish")
        XCTAssertTrue(app.staticTexts["Rendered (silent)"].exists || button("Save to Photos").exists)
        shot("9 Rendered")
    }

    // MARK: Clip strip

    private func tile(_ position: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Clip \(position), ")).firstMatch
    }

    private func seconds(at position: Int) -> String {
        tile(position).label.components(separatedBy: ", ").last ?? ""
    }

    private var strip: XCUIElement {
        app.scrollViews.containing(.button, identifier: "Add clips").firstMatch
    }

    /// Swipes the strip until `target` can be touched.
    private func swipeStrip(left: Bool, until target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 where !target.isHittable {
            left ? strip.swipeLeft() : strip.swipeRight()
        }
        if !target.isHittable { shot("Strip didn't reach \(target.label)") }
        XCTAssertTrue(target.isHittable, "strip never scrolled to \(target)", file: file, line: line)
    }

    /// Long-presses a tile, drags it to the strip's edge and holds there while the strip auto-scrolls.
    private func dragToEdge(_ tile: XCUIElement, right: Bool) {
        let window = app.windows.firstMatch.frame
        let start = tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let edgeX = right ? window.width - 30 : 30
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: edgeX, dy: tile.frame.midY - 10))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 4)
    }

    /// Twelve clips overflow the strip: swiping must scroll it, and long-press-drag must
    /// reorder across it by auto-scrolling. Demo clips repeat 6 s, 5 s, 4 s, so the
    /// durations identify which clip sits where.
    func testClipStripScrollsAndReordersLongSequence() {
        button("New").tap()
        button("Demo clips").tap()
        let addClips = button("Add clips")
        XCTAssertTrue(tile(3).waitForExistence(timeout: 60), "demo clips never arrived")
        for batch in 2...4 {
            swipeStrip(left: true, until: addClips)
            addClips.tap()
            button("Demo clips").tap()
            XCTAssertTrue(tile(batch * 3).waitForExistence(timeout: 60), "batch \(batch) never arrived")
        }
        XCTAssertFalse(tile(13).exists)
        shot("Strip with 12 clips, scrolled to end")

        // Swipes scroll both ways, and a tap still selects.
        swipeStrip(left: false, until: tile(1))
        tile(2).tap()
        XCTAssertTrue(tile(2).isSelected)
        swipeStrip(left: true, until: tile(12))
        tile(11).tap()
        XCTAssertTrue(tile(11).isSelected)
        XCTAssertFalse(tile(2).isSelected)

        // First → last.
        swipeStrip(left: false, until: tile(1))
        XCTAssertEqual(seconds(at: 1), "6.0 seconds")
        XCTAssertEqual(seconds(at: 12), "4.0 seconds")
        dragToEdge(tile(1), right: true)
        sleep(1)
        shot("After dragging first clip to the end")
        XCTAssertEqual(seconds(at: 12), "6.0 seconds", "first clip didn't reach the end")
        XCTAssertEqual(seconds(at: 1), "5.0 seconds")
        XCTAssertTrue(button("Undo Move Clip").exists)
        button("Undo Move Clip").tap()
        XCTAssertEqual(seconds(at: 1), "6.0 seconds")
        XCTAssertEqual(seconds(at: 12), "4.0 seconds")
        XCTAssertFalse(button("Undo Move Clip").exists, "one drag should be one undo step")

        // Last → first. The strip must still scroll after the drag.
        swipeStrip(left: true, until: tile(12))
        dragToEdge(tile(12), right: false)
        sleep(1)
        shot("After dragging last clip to the start")
        XCTAssertEqual(seconds(at: 1), "4.0 seconds", "last clip didn't reach the start")
        XCTAssertEqual(seconds(at: 2), "6.0 seconds")
        XCTAssertEqual(seconds(at: 12), "5.0 seconds")
        button("Undo Move Clip").tap()
        XCTAssertEqual(seconds(at: 1), "6.0 seconds")
        XCTAssertEqual(seconds(at: 12), "4.0 seconds")
        swipeStrip(left: true, until: tile(12))
        swipeStrip(left: false, until: tile(1))

        // Playback keeps the clip under the playhead in view: clip 7 starts off-screen.
        tile(6).tap()
        XCTAssertFalse(tile(7).isHittable)
        button("Play").tap()
        let followed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: tile(7))
        wait(for: [followed], timeout: 10)
        button("Pause").tap()
    }
}
