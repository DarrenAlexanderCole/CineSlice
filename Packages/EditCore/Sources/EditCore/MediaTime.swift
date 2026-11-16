import Foundation

/// Rational media time (value / timescale), mirroring CMTime's representation
/// so edit points are stored exactly rather than as floating-point seconds.
/// The app layer converts to and from CMTime (see CMTime+MediaTime.swift).
public struct MediaTime: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let defaultTimescale: Int32 = 600

    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32 = MediaTime.defaultTimescale) {
        precondition(timescale > 0, "MediaTime timescale must be positive")
        self.value = value
        self.timescale = timescale
    }

    public init(seconds: Double, timescale: Int32 = MediaTime.defaultTimescale) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public static let zero = MediaTime(value: 0)

    public var seconds: Double { Double(value) / Double(timescale) }

    public var description: String { String(format: "%.3fs (%lld/%d)", seconds, value, timescale) }

    /// Re-express in another timescale, rounding to the nearest tick.
    public func converted(to newTimescale: Int32) -> MediaTime {
        if newTimescale == timescale { return self }
        let scaled = (Double(value) * Double(newTimescale) / Double(timescale)).rounded()
        return MediaTime(value: Int64(scaled), timescale: newTimescale)
    }

    /// Multiply the duration by a factor (used for playback speed).
    public func scaled(by factor: Double) -> MediaTime {
        MediaTime(value: Int64((Double(value) * factor).rounded()), timescale: timescale)
    }

    // MARK: Arithmetic in a common timescale

    static func commonTimescale(_ a: Int32, _ b: Int32) -> Int32 {
        if a == b { return a }
        let l = lcm(Int64(a), Int64(b))
        return l <= Int64(Int32.max) ? Int32(l) : max(a, b)
    }

    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        let ts = commonTimescale(lhs.timescale, rhs.timescale)
        return MediaTime(value: lhs.converted(to: ts).value + rhs.converted(to: ts).value, timescale: ts)
    }

    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        let ts = commonTimescale(lhs.timescale, rhs.timescale)
        return MediaTime(value: lhs.converted(to: ts).value - rhs.converted(to: ts).value, timescale: ts)
    }

    public static func += (lhs: inout MediaTime, rhs: MediaTime) { lhs = lhs + rhs }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value < rhs.value }
        let a = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let b = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        if !a.overflow && !b.overflow { return a.partialValue < b.partialValue }
        return lhs.seconds < rhs.seconds
    }

    public static func == (lhs: MediaTime, rhs: MediaTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value == rhs.value }
        return !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        // Equal times in different timescales must hash equally.
        let g = gcd(abs(value), Int64(timescale))
        let d = g == 0 ? 1 : g
        hasher.combine(value / d)
        hasher.combine(Int64(timescale) / d)
    }

    public func clamped(to lower: MediaTime, _ upper: MediaTime) -> MediaTime {
        Swift.min(Swift.max(self, lower), upper)
    }

    /// Timecode text, e.g. "01:02:15" (minutes:seconds:frames).
    public func timecode(frameRate: Double = 30) -> String {
        let fps = Swift.max(1, Int(frameRate.rounded()))
        let totalFrames = Swift.max(0, Int((seconds * Double(fps)).rounded(.down)))
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        return String(format: "%02d:%02d:%02d", totalSeconds / 60, totalSeconds % 60, frames)
    }
}

/// A half-open range [start, start + duration).
public struct MediaTimeRange: Codable, Hashable, Sendable {
    public var start: MediaTime
    public var duration: MediaTime

    public init(start: MediaTime, duration: MediaTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.duration = end - start
    }

    public var end: MediaTime { start + duration }

    public func contains(_ t: MediaTime) -> Bool { t >= start && t < end }
}

private func gcd(_ a: Int64, _ b: Int64) -> Int64 {
    var (x, y) = (abs(a), abs(b))
    while y != 0 { (x, y) = (y, x % y) }
    return x
}

private func lcm(_ a: Int64, _ b: Int64) -> Int64 {
    let g = gcd(a, b)
    return g == 0 ? 0 : (a / g) * b
}
