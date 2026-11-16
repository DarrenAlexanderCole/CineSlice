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
}
