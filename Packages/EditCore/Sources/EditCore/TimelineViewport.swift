import Foundation

/// What part of the timeline the landscape light box shows: a window of composition time
/// (`start` and a zoom in points per second), and how its two sections of lanes, video above the
/// divider and audio below, are scrolled and sized. It is view state only: never saved in the
/// project and never undoable. Zoom, lane height and lane scroll are independent of each other,
/// so resizing lanes never changes the timeline's zoom, and zooming never resizes lanes.
public struct TimelineViewport: Equatable, Sendable {
    /// Composition time, in seconds, at the left edge of the lanes.
    public var start: Double
    /// Horizontal zoom.
    public var pointsPerSecond: Double
    public var video: LaneSection
    public var audio: LaneSection

    public static let minPointsPerSecond = 2.0
    /// At the closest zoom a frame at 30 fps is about 13 points wide.
    public static let maxPointsPerSecond = 400.0

    public init(
        start: Double = 0, pointsPerSecond: Double = 30,
        video: LaneSection = LaneSection(laneHeight: 56, range: 30...220),
        audio: LaneSection = LaneSection(laneHeight: 46, range: 22...160)
    ) {
        self.start = start
        self.pointsPerSecond = pointsPerSecond
        self.video = video
        self.audio = audio
    }

    // MARK: Time ↔ points

    public func x(for seconds: Double) -> Double { (seconds - start) * pointsPerSecond }
    public func seconds(atX x: Double) -> Double { start + x / pointsPerSecond }
    public func span(width: Double) -> Double { width / pointsPerSecond }

    /// Whether `range` (seconds) shows at all in lanes `width` points wide.
    public func isVisible(_ lower: Double, _ upper: Double, width: Double) -> Bool {
        upper > start && lower < start + span(width: width)
    }

    // MARK: Pan and zoom

    /// Points of bare table shown before 00:00 when scrolled to the start, so the lanes don't
    /// begin hard against the edge.
    public static let leadIn = 16.0

    /// The earliest the lanes may start: a lead-in's width before 00:00 at this zoom.
    public var earliestStart: Double { -Self.leadIn / pointsPerSecond }

    /// How far the lanes may scroll: the project from just before its start, with half a screen
    /// of room past the end so the last frames can be brought to the middle.
    public mutating func clampStart(duration: Double, width: Double) {
        let upper = max(earliestStart, duration - span(width: width) / 2)
        start = min(max(start, earliestStart), upper)
    }

    /// Pans by `dx` points (positive drags the picture right, showing earlier time).
    public mutating func pan(by dx: Double, duration: Double, width: Double) {
        start -= dx / pointsPerSecond
        clampStart(duration: duration, width: width)
    }

    /// Zooms by `factor` keeping the time under `anchorX` where it is.
    public mutating func zoom(by factor: Double, anchorX: Double, duration: Double, width: Double) {
        let anchor = seconds(atX: anchorX)
        pointsPerSecond = Self.clampedZoom(pointsPerSecond * factor, duration: duration, width: width)
        start = anchor - anchorX / pointsPerSecond
        clampStart(duration: duration, width: width)
    }

    /// The whole project across the lanes, after the lead-in and with a little room after it.
    public mutating func fit(duration: Double, width: Double) {
        guard duration > 0, width > Self.leadIn else { return }
        pointsPerSecond = Self.clampedZoom((width - Self.leadIn) / (duration * 1.04), duration: duration, width: width)
        start = earliestStart
    }

    /// Zoom limits; the widest still shows the whole project.
    public static func clampedZoom(_ pps: Double, duration: Double, width: Double) -> Double {
        let widest = duration > 0 && width > 0 ? min(minPointsPerSecond, width / (duration * 1.04)) : minPointsPerSecond
        return min(max(pps, widest), maxPointsPerSecond)
    }

    /// Keeps the playhead on screen: once it passes `trailing` (a fraction of the width) the lanes
    /// scroll with it, and if it is off the left they bring it back in at `leading`.
    public mutating func follow(
        _ playhead: Double, width: Double, duration: Double,
        leading: Double = 0.15, trailing: Double = 0.85
    ) {
        let span = span(width: width)
        guard span > 0 else { return }
        if playhead > start + span * trailing {
            start = playhead - span * trailing
        } else if playhead < start {
            start = playhead - span * leading
        }
        clampStart(duration: duration, width: width)
    }

    // MARK: Ruler and film tiles

    /// Seconds between labelled ruler marks, the smallest "nice" step that keeps labels at
    /// least `minLabelSpacing` points apart.
    public func rulerStep(minLabelSpacing: Double = 56) -> Double {
        let steps: [Double] = [0.5, 1, 2, 4, 5, 10, 15, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600]
        return steps.first { $0 * pointsPerSecond >= minLabelSpacing } ?? steps.last!
    }

    /// How much time each film frame tile covers when tiles are about `nominalWidth` points wide.
    /// Snapped to a power of two (in seconds) so zooming reuses frames already decoded, and
    /// tiles sit on fixed times so they don't swim while panning.
    public func tileDuration(nominalWidth: Double) -> Double {
        let raw = nominalWidth / pointsPerSecond
        return pow(2, (log2(max(raw, 1.0 / 64))).rounded())
    }
}

/// One section of the light box (video lanes above the divider, or audio lanes below): how tall
/// each lane is and how far the section is scrolled. Lanes stack outward from the divider.
public struct LaneSection: Equatable, Sendable {
    public var laneHeight: Double
    /// Points scrolled away from the divider (0 shows the lane next to it).
    public var scroll: Double = 0
    public let range: ClosedRange<Double>

    public init(laneHeight: Double, range: ClosedRange<Double>) {
        self.range = range
        self.laneHeight = min(max(laneHeight, range.lowerBound), range.upperBound)
    }

    public static let spacing = 6.0

    public func contentHeight(lanes: Int) -> Double {
        lanes == 0 ? 0 : Double(lanes) * laneHeight + Double(lanes + 1) * Self.spacing
    }

    public func maxScroll(lanes: Int, viewport: Double) -> Double {
        max(0, contentHeight(lanes: lanes) - viewport)
    }

    /// Scrolls by `delta` points, clamped to the lanes there are. Returns how far it actually
    /// moved, so a roller can stop turning at the ends.
    @discardableResult
    public mutating func scroll(by delta: Double, lanes: Int, viewport: Double) -> Double {
        let before = scroll
        scroll = min(max(scroll + delta, 0), maxScroll(lanes: lanes, viewport: viewport))
        return scroll - before
    }

    /// Resizes lanes by `delta` points, keeping the lane that sits at the middle of the section
    /// where it is (the anchor), then clamps the scroll.
    @discardableResult
    public mutating func resize(by delta: Double, lanes: Int, viewport: Double) -> Double {
        let before = laneHeight
        let new = min(max(laneHeight + delta, range.lowerBound), range.upperBound)
        guard new != before else { return 0 }
        // The point at the middle of the section, as a fraction through the lanes.
        let mid = scroll + viewport / 2
        let pitch = before + Self.spacing
        let fraction = (mid - Self.spacing) / pitch
        laneHeight = new
        scroll = fraction * (new + Self.spacing) + Self.spacing - viewport / 2
        scroll = min(max(scroll, 0), maxScroll(lanes: lanes, viewport: viewport))
        return new - before
    }

    public mutating func clamp(lanes: Int, viewport: Double) {
        scroll = min(max(scroll, 0), maxScroll(lanes: lanes, viewport: viewport))
    }
}

/// The big horizontal jog roller, worked like the upright jog dial: near where the finger lands
/// it jogs, a frame per `pointsPerFrame`; pushed further out and held, it plays, faster the
/// further out it goes (backwards to the left), and letting go stops.
public struct JogRollerMapping: Sendable {
    public var pointsPerFrame: Double = 7
    /// How far either side of the touch-down point still jogs.
    public var jogZone: Double = 30
    /// Travel beyond the jog zone to reach the fastest shuttle speed.
    public var shuttleReach: Double = 110
    /// How many shuttle speeds there are.
    public var shuttleSteps = 5

    public init() {}

    /// Frames (fractional) for `dx` points dragged inside the jog zone.
    public func frames(dx: Double) -> Double { dx / pointsPerFrame }

    /// The signed shuttle step for a drag `offset` points from where the finger landed: 0 jogging,
    /// ±1…±`shuttleSteps` playing, the step rising quickly the further out it goes.
    public func shuttleLevel(offset: Double) -> Int {
        let distance = abs(offset)
        guard distance > jogZone else { return 0 }
        let step = min(shuttleSteps, 1 + Int((distance - jogZone) / shuttleReach * Double(shuttleSteps)))
        return offset > 0 ? step : -step
    }
}
