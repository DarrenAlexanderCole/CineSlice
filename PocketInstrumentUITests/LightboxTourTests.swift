import XCTest

/// Turns the phone sideways in a project with the demo clips and click track, works LIGHTBOX's
/// rollers and Tools, and turns back. Attaches a screenshot of each state for judging the layout.
final class LightboxTourTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-skipIntro"]
        app.launchEnvironment["DEMO_PHOTOS"] = ProcessInfo.processInfo.environment["DEMO_PHOTOS"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLightboxTour() {
        XCTAssertTrue(button("New").waitForExistence(timeout: 10))
        button("New").tap()
        button("Demo clips").tap()
        XCTAssertTrue(button("Mix").waitForExistence(timeout: 60), "demo clips never arrived")
        button("Mix").tap()
        let choose = button("Choose music")
        (choose.waitForExistence(timeout: 5) ? choose : button("Music")).tap()
        button("My Music").tap()
        button("Demo click track").tap()
        XCTAssertTrue(element("Music position").waitForExistence(timeout: 30), "music never arrived")
        button("Arrange").tap()

        // Sideways: the light box, with the same project.
        XCUIDevice.shared.orientation = .landscapeLeft
        let roller = element("Playhead roller")
        XCTAssertTrue(roller.waitForExistence(timeout: 5), "turning sideways should open LIGHTBOX")
        sleep(2)
        shot("L1 Lightbox resting")

        // A careful push on the playhead roller, inside its jog zone, moves it a few frames.
        let before = roller.value as? String
        let middle = roller.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7))
        middle.press(
            forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 24, dy: 0)), withVelocity: 60,
            thenHoldForDuration: 0.1)
        XCTAssertNotEqual(roller.value as? String, before, "the roller should move the playhead")

        // Taller video lanes, then scroll them; taller audio lanes.
        let videoSize = element("Video lane height")
        let sizeBefore = videoSize.value as? String
        videoSize.swipeUp(velocity: .slow)
        XCTAssertNotEqual(videoSize.value as? String, sizeBefore, "the size roller should resize video lanes")
        // All ten video lanes are always there: the scroll roller climbs them, and comes back to V1.
        let videoScroll = element("Video lane scroll")
        let scrolledFrom = videoScroll.value as? String
        videoScroll.swipeDown(velocity: .slow)
        XCTAssertNotEqual(videoScroll.value as? String, scrolledFrom, "the scroll roller should climb the lanes")
        for _ in 0..<3 where videoScroll.value as? String != scrolledFrom { videoScroll.swipeUp(velocity: .fast) }
        // The A/V switch hands the same two rollers to the audio lanes.
        button("Roller lanes").tap()
        XCTAssertEqual(button("Roller lanes").value as? String, "Audio")
        element("Audio lane height").swipeUp(velocity: .slow)
        sleep(1)
        shot("L2 Lanes resized")

        // Tools: Scissor cuts at the playhead, as one undo step.
        button("Tools").tap()
        let scissor = button("Scissor: cut at playhead")
        XCTAssertTrue(scissor.waitForExistence(timeout: 5))
        sleep(1)
        shot("L3 Tools open")
        // The playhead is inside the first clip, which is selected.
        XCTAssertTrue(scissor.isEnabled, "the playhead should be inside the selected clip")
        scissor.tap()
        XCTAssertTrue(button("Undo Split Clip").waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertFalse(scissor.exists, "a tap outside the tray closes it")

        let atCut = roller.value as? String
        button("Next cut").tap()
        XCTAssertNotEqual(roller.value as? String, atCut, "Next cut should move the playhead")
        button("Fit whole project").tap()
        sleep(1)
        shot("L4 After a cut, fitted")

        // The monitor key gives the table the whole width, and brings the picture back.
        button("Monitor").tap()
        XCTAssertEqual(button("Monitor").value as? String, "Hidden")
        XCTAssertFalse(button("Preview").waitForExistence(timeout: 1), "the monitor should be away")
        sleep(1)
        shot("L4a Full timeline")
        button("Monitor").tap()
        XCTAssertTrue(button("Preview").waitForExistence(timeout: 5), "the monitor should be back")

        // Pushed out and held, the roller plays; letting go stops.
        let beforeShuttle = roller.value as? String
        middle.press(
            forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 70, dy: 0)), withVelocity: 400,
            thenHoldForDuration: 1.5)
        sleep(1)
        XCTAssertNotEqual(roller.value as? String, beforeShuttle, "holding the roller out should play")

        // A long press lifts the first clip; dragging it right moves it later, as one undo step.
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "starts at 0.0")).firstMatch
        XCTAssertTrue(first.exists)
        let grab = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(
            forDuration: 0.6, thenDragTo: grab.withOffset(CGVector(dx: 260, dy: 0)), withVelocity: 300,
            thenHoldForDuration: 0.2)
        XCTAssertTrue(button("Undo Move Clip").waitForExistence(timeout: 5), "dropping the clip moves it")
        sleep(1)
        shot("L4b Clip moved")

        // Footage straight onto the table, at the playhead: it's over the sequence, so the
        // clips go on the lane above, V2, and nothing in the sequence moves.
        button("Add clips").tap()
        button("Demo clips").tap()
        XCTAssertTrue(button("Undo Add Clips").waitForExistence(timeout: 60), "demo clips should land on the table")
        let stacked = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Stacked clip"))
        XCTAssertTrue(stacked.firstMatch.waitForExistence(timeout: 5), "over the sequence they stack on V2")
        XCTAssertEqual(stacked.firstMatch.value as? String, "Lane V2")
        // The song, at the playhead on the first audio lane with room.
        button("Music").tap()
        button("My Music").tap()
        button("Demo click track").tap()
        XCTAssertTrue(roller.waitForExistence(timeout: 10))
        sleep(3)
        shot("L4c Brought in")

        // The music slides along its lane: one undo step.
        let music = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Music:"))
            .firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        let musicGrab = music.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        musicGrab.press(
            forDuration: 0.6, thenDragTo: musicGrab.withOffset(CGVector(dx: 60, dy: 0)), withVelocity: 300,
            thenHoldForDuration: 0.2)
        XCTAssertTrue(button("Undo Move Music").waitForExistence(timeout: 5), "dropping the music moves it")

        // A stacked clip lifted up onto the next lane: one undo step.
        let selectedStack = stacked.matching(NSPredicate(format: "selected == true")).firstMatch
        let stackGrab = selectedStack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        stackGrab.press(
            forDuration: 0.6, thenDragTo: stackGrab.withOffset(CGVector(dx: 40, dy: -70)), withVelocity: 300,
            thenHoldForDuration: 0.3)
        XCTAssertTrue(button("Undo Move Clip").waitForExistence(timeout: 5), "dropping it moves it")
        sleep(1)
        shot("L4c3 Stacked moved")

        // Sounds land at the playhead on the lanes under the music; the second, overlapping the
        // first, gets a lane of its own.
        button("Add sound").tap()
        button("Demo sound").tap()
        XCTAssertTrue(button("Undo Add Sound").waitForExistence(timeout: 20), "a sound should land on a lane")
        button("Add sound").tap()
        button("Demo sound").tap()
        let sounds = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sound:"))
        let two = NSPredicate(format: "count == 2")
        expectation(for: two, evaluatedWith: sounds)
        waitForExpectations(timeout: 20)
        sleep(1)
        shot("L4d Sounds")

        // Lifted and dragged later along its lane: one undo step.
        // The one just added is selected, and its lane scrolled into view.
        let sound = sounds.matching(NSPredicate(format: "selected == true")).firstMatch
        let lift = sound.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        lift.press(
            forDuration: 0.6, thenDragTo: lift.withOffset(CGVector(dx: 160, dy: 0)), withVelocity: 300,
            thenHoldForDuration: 0.2)
        XCTAssertTrue(button("Undo Move Sound").waitForExistence(timeout: 5), "dropping the sound moves it")
        sleep(1)
        shot("L4e Sound moved")

        // Volume: the selected sound's level, and its lane's mute; each one undo step.
        button("Tools").tap()
        button("Volume").tap()
        let soundLevel = element("Sound level")
        XCTAssertTrue(soundLevel.waitForExistence(timeout: 5), "Volume opens the level panel")
        let high = soundLevel.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.75))
        high.press(
            forDuration: 0.05, thenDragTo: soundLevel.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.75)),
            withVelocity: 300, thenHoldForDuration: 0.1)
        XCTAssertTrue(button("Undo Sound Level").waitForExistence(timeout: 5), "the fader sets the level")
        button("Mute lane").tap()
        XCTAssertTrue(button("Undo Mute Lane").waitForExistence(timeout: 5))
        XCTAssertEqual(button("Mute lane").value as? String, "Muted")
        button("Mute lane").tap()
        // Fade: the selected sound's fade in.
        button("Fade").tap()
        let fadeIn = element("Fade in")
        XCTAssertTrue(fadeIn.waitForExistence(timeout: 5), "Fade opens the fade panel")
        fadeIn.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.75)).press(
            forDuration: 0.05, thenDragTo: fadeIn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
            withVelocity: 300, thenHoldForDuration: 0.1)
        XCTAssertTrue(button("Undo Sound Fades").waitForExistence(timeout: 5), "the fader sets the fade")
        sleep(1)
        shot("L4f Sound fades")
        // Closed, the tray shows the sound's level and fade drawn on its glass.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        sleep(1)
        shot("L4g Fade drawn")

        // Remove takes the selected sound off its lane.
        button("Tools").tap()
        button("Remove").tap()
        XCTAssertTrue(button("Undo Remove Sound").waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()

        // Preview opens Watch and comes back to the same frame.
        let frame = roller.value as? String
        button("Preview").tap()
        XCTAssertTrue(button("Done").waitForExistence(timeout: 5) || app.otherElements.firstMatch.exists)
        sleep(2)
        shot("L5 Preview")
        app.tap()
        button("Done").tap()
        XCTAssertTrue(roller.waitForExistence(timeout: 5))
        XCTAssertEqual(roller.value as? String, frame, "Preview should return to the same frame")

        // Upright again: the cut is there to undo.
        XCUIDevice.shared.orientation = .portrait
        let undo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Undo ")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the edits survive turning back")
        sleep(1)
        shot("L6 Upright again")
    }
}
