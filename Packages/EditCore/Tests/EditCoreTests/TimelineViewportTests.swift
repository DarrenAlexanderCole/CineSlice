import XCTest

@testable import EditCore

final class TimelineViewportTests: XCTestCase {
    func testTimeAndPointsRoundTrip() {
        let v = TimelineViewport(start: 4, pointsPerSecond: 50)
        XCTAssertEqual(v.x(for: 6), 100)
        XCTAssertEqual(v.seconds(atX: 100), 6)
        XCTAssertTrue(v.isVisible(3, 4.5, width: 100))
        XCTAssertFalse(v.isVisible(6.5, 9, width: 100))
    }

    func testZoomKeepsTheAnchorUnderTheFingers() {
        var v = TimelineViewport(start: 10, pointsPerSecond: 40)
        let anchor = v.seconds(atX: 200)
        v.zoom(by: 2, anchorX: 200, duration: 120, width: 600)
        XCTAssertEqual(v.pointsPerSecond, 80)
        XCTAssertEqual(v.seconds(atX: 200), anchor, accuracy: 1e-9)
    }

    func testZoomIsClampedAndWidestShowsTheWholeProject() {
        var v = TimelineViewport()
        v.zoom(by: 1000, anchorX: 0, duration: 60, width: 600)
        XCTAssertEqual(v.pointsPerSecond, TimelineViewport.maxPointsPerSecond)
        v.zoom(by: 0.000_01, anchorX: 0, duration: 3600, width: 600)
        XCTAssertLessThanOrEqual(v.pointsPerSecond * 3600, 600)
    }

    func testPanStopsAtTheProjectBounds() {
        var v = TimelineViewport(start: 0, pointsPerSecond: 10)
        v.pan(by: 500, duration: 100, width: 400)
        XCTAssertEqual(v.start, v.earliestStart, "can't scroll past the lead-in before the start")
        XCTAssertEqual(v.x(for: 0), TimelineViewport.leadIn, accuracy: 1e-9)
        v.pan(by: -100_000, duration: 100, width: 400)
        XCTAssertEqual(v.start, 100 - 20, "stops with the end at the middle")
    }

    func testFitShowsEverything() {
        var v = TimelineViewport(start: 33, pointsPerSecond: 300)
        v.fit(duration: 50, width: 520)
        XCTAssertEqual(v.x(for: 0), TimelineViewport.leadIn, accuracy: 1e-9, "00:00 sits after the lead-in")
        XCTAssertLessThanOrEqual(v.x(for: 50), 520)
        XCTAssertGreaterThan(v.x(for: 50), 480)
    }

    func testFollowScrollsWithThePlayhead() {
        var v = TimelineViewport(start: 0, pointsPerSecond: 10)  // 40 s across 400 pt
        v.follow(20, width: 400, duration: 200)
        XCTAssertEqual(v.start, 0, "inside the window: nothing moves")
        v.follow(36, width: 400, duration: 200)
        XCTAssertEqual(v.start, 2, accuracy: 1e-9)
        v.follow(1, width: 400, duration: 200)
        XCTAssertEqual(v.start, v.earliestStart, "jumping back brings the playhead in from the left")
    }

    func testRulerStepKeepsLabelsApart() {
        XCTAssertEqual(TimelineViewport(pointsPerSecond: 14).rulerStep(), 4)
        XCTAssertEqual(TimelineViewport(pointsPerSecond: 200).rulerStep(), 0.5)
        XCTAssertEqual(TimelineViewport(pointsPerSecond: 2).rulerStep(), 30)
    }

    func testTileDurationsArePowersOfTwo() {
        let v = TimelineViewport(pointsPerSecond: 30)
        let d = v.tileDuration(nominalWidth: 100)
        XCTAssertEqual(d, 4)  // 3.33 s rounds to 2^2
        XCTAssertEqual(
            log2(TimelineViewport(pointsPerSecond: 333).tileDuration(nominalWidth: 100)).truncatingRemainder(
                dividingBy: 1), 0)
    }

    func testLaneScrollClampsToContent() {
        var s = LaneSection(laneHeight: 60, range: 30...200)
        XCTAssertEqual(s.scroll(by: 50, lanes: 1, viewport: 120), 0, "one short lane: nothing to scroll")
        _ = s.scroll(by: 1000, lanes: 4, viewport: 120)
        XCTAssertEqual(s.scroll, s.contentHeight(lanes: 4) - 120)
        _ = s.scroll(by: -5000, lanes: 4, viewport: 120)
        XCTAssertEqual(s.scroll, 0)
    }

    func testLaneResizeClampsAndKeepsTheMiddleLane() {
        var s = LaneSection(laneHeight: 60, range: 30...200)
        s.scroll = 100
        let lanes = 6
        let viewport = 120.0
        let midLane = Int((s.scroll + viewport / 2 - LaneSection.spacing) / (s.laneHeight + LaneSection.spacing))
        s.resize(by: 40, lanes: lanes, viewport: viewport)
        XCTAssertEqual(s.laneHeight, 100)
        let after = Int((s.scroll + viewport / 2 - LaneSection.spacing) / (s.laneHeight + LaneSection.spacing))
        XCTAssertEqual(after, midLane)
        s.resize(by: 10_000, lanes: lanes, viewport: viewport)
        XCTAssertEqual(s.laneHeight, 200)
        s.resize(by: -10_000, lanes: lanes, viewport: viewport)
        XCTAssertEqual(s.laneHeight, 30)
    }

    func testJogStepsFramesNearTheTouchAndShuttlesPushedOut() {
        let jog = JogRollerMapping()
        XCTAssertEqual(jog.frames(dx: 7), 1)
        XCTAssertEqual(jog.frames(dx: -14), -2)
        XCTAssertEqual(jog.shuttleLevel(offset: 0), 0)
        XCTAssertEqual(jog.shuttleLevel(offset: jog.jogZone), 0, "the jog zone's edge still jogs")
        XCTAssertEqual(jog.shuttleLevel(offset: jog.jogZone + 1), 1)
        XCTAssertEqual(jog.shuttleLevel(offset: -(jog.jogZone + 1)), -1, "left plays backwards")
        XCTAssertEqual(jog.shuttleLevel(offset: 10_000), jog.shuttleSteps)
        XCTAssertEqual(jog.shuttleLevel(offset: -10_000), -jog.shuttleSteps)
    }

    func testSourceWaveformCacheSitsBesideTheMusics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ProjectStore(rootURL: root)
        let project = UUID()
        let source = SourceAsset(fileName: "a.mov", duration: MediaTime(seconds: 1), width: 1, height: 1)
        let track = AudioTrack(fileName: "m.m4a", duration: MediaTime(seconds: 1))
        XCTAssertEqual(
            store.waveformCacheURL(for: source, projectID: project).deletingLastPathComponent(),
            store.waveformCacheURL(for: track, projectID: project).deletingLastPathComponent())
        XCTAssertEqual(store.waveformCacheURL(for: source, projectID: project).lastPathComponent, "a.mov.waveform")
    }
}
