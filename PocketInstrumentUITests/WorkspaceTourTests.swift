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
        XCTAssertTrue(button("New").waitForExistence(timeout: 10))
        sleep(1)
        shot("0 Library")
        button("Storage").tap()
        XCTAssertTrue(button("Clear temporary files").waitForExistence(timeout: 5))
        sleep(1)
        shot("0b Storage")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(button("New").waitForExistence(timeout: 5))
        button("New").tap()
        button("Demo clips").tap()
        XCTAssertTrue(button("Mix").waitForExistence(timeout: 60), "demo clips never arrived")
        sleep(2)
        shot("1 Arrange, no music")

        // The viewfinder turns the picture to 16:9 and back.
        let shape = button("Picture shape")
        shape.tap()
        XCTAssertEqual(shape.value as? String, "16:9 horizontal")
        sleep(2)
        shot("1b Arrange, 16:9")
        shape.tap()
        XCTAssertEqual(shape.value as? String, "9:16 vertical")

        // Crop pushes in on the selected clip: pinch its frame over the picture, then drag it.
        button("Crop").tap()
        let crop = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Crop frame'")).firstMatch
        XCTAssertTrue(crop.waitForExistence(timeout: 5))
        crop.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(button("Undo Crop Clip").waitForExistence(timeout: 5))
        let middle = crop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 20, dy: 30)))
        sleep(1)
        shot("1c Cropping clip 1")
        button("Done cropping").tap()
        XCTAssertFalse(crop.exists)
        XCTAssertTrue((button("Crop").value as? String ?? "").hasSuffix("times"), "the clip kept no crop")
        sleep(2)
        shot("1d Clip 1 pushed in")

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

        // The jog dial: a small drag in the middle inches the playhead forward a few frames…
        let dial = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Jog dial'")).firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 5))
        let clock = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' seconds'")).firstMatch
        let seconds = { Double(clock.label.components(separatedBy: " ")[0]) ?? -1 }
        let before = seconds()
        let centre = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(
            forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 16, dy: 0)), withVelocity: 80,
            thenHoldForDuration: 0.2)
        sleep(1)
        let jogged = seconds()
        XCTAssertGreaterThan(jogged, before, "the dial didn't jog")
        XCTAssertLessThan(jogged - before, 0.5, "a small drag should only move a few frames")
        shot("6b Trim after jogging")
        // …and pushed out to the edge and held, it plays fast, stopping when let go.
        centre.press(
            forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 120, dy: 0)), withVelocity: 600,
            thenHoldForDuration: 1.0)
        sleep(1)
        let shuttled = seconds()
        XCTAssertGreaterThan(shuttled - jogged, 1.5, "holding the dial out didn't shuttle")
        sleep(1)
        XCTAssertEqual(seconds(), shuttled, "playback should stop when the dial is let go")

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

        // Playback keeps the clip under the playhead in view: clip 8 starts off-screen, 10 s on.
        tile(6).tap()
        XCTAssertFalse(tile(8).isHittable)
        button("Play").tap()
        let followed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: tile(8))
        wait(for: [followed], timeout: 16)
        button("Pause").tap()
    }

    // MARK: Automation

    private var musicFader: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "MUSIC")).firstMatch
    }

    /// Rides the music fader from near the top to lower down, slowly, then holds.
    private func rideMusicFader() {
        let start = musicFader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.75))
        let end = musicFader.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.75))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: 80, thenHoldForDuration: 1)
    }

    /// With Write on, riding a fader during playback records one pass (one undo step) that
    /// can be cleared from the Clear key; with Write off the same move only sets the static level.
    func testRecordingAMusicCurve() {
        button("New").tap()
        button("Demo clips").tap()
        XCTAssertTrue(button("Mix").waitForExistence(timeout: 60), "demo clips never arrived")
        button("Mix").tap()
        button("Demo click track").tap()
        XCTAssertTrue(musicFader.waitForExistence(timeout: 30))
        let write = button("Write automation")
        XCTAssertTrue(write.waitForExistence(timeout: 30))

        // Write off: a fader move is a static level change.
        button("Play").tap()
        rideMusicFader()
        XCTAssertTrue(button("Undo Music Level").waitForExistence(timeout: 5))
        button("Pause").tap()

        write.tap()
        XCTAssertEqual(write.value as? String, "On")
        button("Play").tap()
        sleep(1)
        rideMusicFader()
        XCTAssertTrue(button("Undo Record Music Level").waitForExistence(timeout: 5), "no pass was recorded")
        shot("Mix with a recorded music curve")
        button("Pause").tap()

        button("Clear automation").tap()
        let clear = button("Clear music curve")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(button("Undo Clear Music Curve").waitForExistence(timeout: 5))
        button("Undo Clear Music Curve").tap()
        XCTAssertTrue(button("Undo Record Music Level").waitForExistence(timeout: 5))

        // Locked music can't be nudged; unlocking frees it again.
        let lock = button("Lock music")
        lock.tap()
        XCTAssertTrue((lock.value as? String)?.lowercased().hasPrefix("locked") ?? false)
        XCTAssertFalse(button("Music one frame later").isEnabled)
        XCTAssertTrue(button("Undo Lock Music").exists)
        lock.tap()
        XCTAssertTrue(button("Music one frame later").isEnabled)

        // Editing the music curve by hand: tap the band to add a point, drag one, double-tap one away.
        let edit = button("Edit curve")
        edit.tap()
        let editMusic = button("Edit music curve")
        XCTAssertTrue(editMusic.waitForExistence(timeout: 5))
        editMusic.tap()
        let labelled = { (label: String) in
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        }
        let band = labelled("Music curve").firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        let points = labelled("Curve point")
        let before = points.count
        XCTAssertGreaterThan(before, 1, "the recorded pass should show its points")
        sleep(1)
        shot("Editing the music curve")
        band.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.3)).tap()
        XCTAssertTrue(button("Undo Add Curve Point").waitForExistence(timeout: 5))
        XCTAssertGreaterThan(points.count, before)
        let first = points.element(boundBy: 0)
        let center = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 12, dy: 30)))
        XCTAssertTrue(button("Undo Move Curve Point").waitForExistence(timeout: 5))
        shot("Music curve point moved")
        let count = points.count
        points.element(boundBy: 0).doubleTap()
        XCTAssertTrue(button("Undo Delete Curve Point").waitForExistence(timeout: 5))
        XCTAssertEqual(points.count, count - 1)
        // Off a point (here, above the recorded pass), a drag draws the curve.
        let from = band.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.08))
        from.press(forDuration: 0.1, thenDragTo: band.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        XCTAssertTrue(button("Undo Draw Music Curve").waitForExistence(timeout: 5))
        shot("Music curve drawn by finger")
        // A tapped point is selected, and the jog dial then inches it along in time.
        points.element(boundBy: 0).tap()
        let dial = labelled("Jog dial").firstMatch
        XCTAssertEqual(dial.value as? String, "Point")
        let knob = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        knob.press(
            forDuration: 0.05, thenDragTo: knob.withOffset(CGVector(dx: 25, dy: 0)), withVelocity: 120,
            thenHoldForDuration: 0.2)
        XCTAssertTrue(button("Undo Move Curve Point").waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertFalse(band.waitForExistence(timeout: 1))

        // Zooming the lane steps 1× → 4× → 16× and back.
        let zoom = button("Zoom sequence")
        XCTAssertEqual(zoom.value as? String, "1×")
        zoom.tap()
        XCTAssertEqual(zoom.value as? String, "4×")
        sleep(1)
        shot("Mix lane zoomed 4×")
        zoom.tap()
        zoom.tap()
        XCTAssertEqual(zoom.value as? String, "1×")

        // Watch: only the picture, playing; a tap brings up Done.
        button("Watch").tap()
        XCTAssertFalse(button("Mix").waitForExistence(timeout: 1), "the deck should be hidden")
        sleep(1)
        shot("Watch")
        // Tapping the left edge marks In on the clip that's playing, without stopping.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        shot("Watch, marked In")
        // A double tap in the middle clears that clip's In and Out again.
        app.doubleTap()
        shot("Watch, cleared")
        sleep(1)
        app.tap()
        XCTAssertTrue(button("Pause").waitForExistence(timeout: 3), "marking should keep it playing")
        button("Done").tap()
        XCTAssertTrue(button("Mix").waitForExistence(timeout: 3))
        XCTAssertTrue(button("Undo Trim Clip").exists)
        button("Pause").tap()
    }
}
