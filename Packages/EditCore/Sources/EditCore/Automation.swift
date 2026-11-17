import Foundation

// MARK: - Volume automation

/// Which level a curve drives.
public enum AutomationTarget: String, Codable, CaseIterable, Sendable {
    /// The clips' own sound. Each clip carries its own curve (`TimelineClip.levelCurve`), which
    /// overrides that clip's static level where recorded.
    case clipAudio
    /// The reference music. Overrides the music fader where recorded.
    case music
}

/// A level (0…1) at a time: composition time for the music, source time inside a clip's curve.
public struct AutomationPoint: Codable, Hashable, Sendable {
    public var time: MediaTime
    public var value: Float
    public init(time: MediaTime, value: Float) {
        self.time = time
        self.value = value
    }
}

/// One recorded pass: points sorted by time, at least two, ramping linearly between them.
public struct AutomationSegment: Codable, Hashable, Sendable {
    public var points: [AutomationPoint]

    public init(points: [AutomationPoint]) { self.points = points }

    public var start: MediaTime { points.first?.time ?? .zero }
    public var end: MediaTime { points.last?.time ?? .zero }

    /// Linear interpolation inside the segment; clamps to the end values outside it.
    public func value(at t: MediaTime) -> Float {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        let i = points.firstIndex { $0.time > t } ?? points.count - 1
        return lerp(points[i - 1], points[i], at: t)
    }

    /// The part of the segment inside [from, to], cut with interpolated end points.
    func slice(from: MediaTime, to: MediaTime) -> AutomationSegment? {
        let lower = max(from, start)
        let upper = min(to, end)
        guard upper > lower else { return nil }
        var sliced = [AutomationPoint(time: lower, value: value(at: lower))]
        sliced += points.filter { $0.time > lower && $0.time < upper }
        sliced.append(AutomationPoint(time: upper, value: value(at: upper)))
        return AutomationSegment(points: sliced)
    }
}

/// One curve: recorded passes in time order, never overlapping. Between passes the
/// static level applies; the edges of each pass ease to and from it over `glide`.
/// The music curve is in composition time, so it stays put when clips are reordered or trimmed;
/// a clip's curve is in that clip's source time, so it travels with the clip.
public struct AutomationLane: Codable, Hashable, Sendable {
    public var segments: [AutomationSegment]

    public init(segments: [AutomationSegment] = []) { self.segments = segments }

    public var isEmpty: Bool { segments.isEmpty }

    /// The recorded level at `t`, or nil where no pass covers it.
    public func value(at t: MediaTime) -> Float? {
        segments.first { $0.start <= t && t <= $0.end }?.value(at: t)
    }

    /// How long each pass's edges take to ease to or from the static level.
    public static let glide = MediaTime(value: 90, timescale: 600)

    /// Level change below which a recorded point is dropped as redundant (1%).
    public static let tolerance: Float = 0.01

    /// Replaces whatever the pass overlaps with the pass, splitting an older pass it lands inside.
    mutating func write(_ pass: AutomationSegment) {
        var kept: [AutomationSegment] = []
        for segment in segments {
            if segment.end <= pass.start || segment.start >= pass.end {
                kept.append(segment)
                continue
            }
            if let before = segment.slice(from: segment.start, to: pass.start) { kept.append(before) }
            if let after = segment.slice(from: pass.end, to: segment.end) { kept.append(after) }
        }
        kept.append(pass)
        segments = kept.sorted { $0.start < $1.start }
    }

    /// Raises or lowers the pass covering `t` by `delta`, keeping its shape; levels clamp to 0…1.
    /// False when no pass covers `t`.
    mutating func shiftPass(containing t: MediaTime, by delta: Float) -> Bool {
        guard let i = segments.firstIndex(where: { $0.start <= t && t <= $0.end }) else { return false }
        for j in segments[i].points.indices {
            segments[i].points[j].value = min(max(segments[i].points[j].value + delta, 0), 1)
        }
        return true
    }
}

/// The project-wide curves. Clip curves live on the clips.
public struct Automation: Codable, Hashable, Sendable {
    public var music: AutomationLane

    public init(music: AutomationLane = .init()) { self.music = music }

    enum CodingKeys: String, CodingKey { case music }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        music = try c.decodeIfPresent(AutomationLane.self, forKey: .music) ?? AutomationLane()
    }
}

// MARK: - Clip curves

extension TimelineClip {
    /// The used part of this clip's curve on the composition timeline, for a clip starting at `start`.
    func compositionCurve(startingAt start: MediaTime) -> [AutomationSegment] {
        levelCurve.segments.compactMap { segment in
            segment.slice(from: sourceRange.start, to: sourceRange.end).map { used in
                AutomationSegment(
                    points: used.points.map { p in
                        let local = p.time - sourceRange.start
                        return AutomationPoint(
                            time: start + (speed == 1 ? local : local.scaled(by: 1 / speed)), value: p.value)
                    })
            }
        }
    }
}

extension Project {
    /// A target's recorded passes in composition time. For clip sound, each clip's curve placed
    /// where the clip plays; passes never cross a cut.
    public func lane(for target: AutomationTarget) -> AutomationLane {
        switch target {
        case .music:
            return automation.music
        case .clipAudio:
            var segments: [AutomationSegment] = []
            var cursor = MediaTime.zero
            for clip in clips {
                segments += clip.compositionCurve(startingAt: cursor)
                cursor += clip.compositionDuration
            }
            return AutomationLane(segments: segments)
        }
    }

    /// Writes a composition-time pass into the curves of the clips it plays over, split at the cuts.
    mutating func writeClipLevel(_ pass: AutomationSegment) {
        var cursor = MediaTime.zero
        for i in clips.indices {
            let start = cursor
            let clip = clips[i]
            cursor += clip.compositionDuration
            guard let part = pass.slice(from: start, to: cursor) else { continue }
            let points = part.points.map { p in
                let local = p.time - start
                return AutomationPoint(
                    time: clip.sourceRange.start + (clip.speed == 1 ? local : local.scaled(by: clip.speed)),
                    value: p.value)
            }
            guard let first = points.first, let last = points.last, last.time > first.time else { continue }
            clips[i].levelCurve.write(AutomationSegment(points: points))
        }
    }
}

// MARK: - Recording

extension AutomationSegment {
    /// Cleans up raw fader samples for storage: sorted, one point per time, levels and
    /// times clamped, and points that a straight line already reproduces within
    /// `AutomationLane.tolerance` removed. nil if fewer than two distinct times remain.
    public init?(recorded samples: [AutomationPoint], sequenceDuration: MediaTime) {
        var points: [AutomationPoint] = []
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            let point = AutomationPoint(
                time: sample.time.clamped(to: .zero, sequenceDuration), value: min(max(sample.value, 0), 1))
            if let last = points.last, last.time == point.time {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        guard points.count >= 2 else { return nil }
        self.init(points: simplify(points, tolerance: AutomationLane.tolerance))
    }
}

/// Ramer–Douglas–Peucker on level error: keeps the point furthest from the straight
/// line between the ends whenever it is off by more than `tolerance`.
func simplify(_ points: [AutomationPoint], tolerance: Float) -> [AutomationPoint] {
    guard points.count > 2 else { return points }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var spans = [(0, points.count - 1)]
    while let (a, b) = spans.popLast() {
        guard b - a > 1 else { continue }
        var worst = a
        var worstError: Float = 0
        for i in (a + 1)..<b {
            let error = abs(points[i].value - lerp(points[a], points[b], at: points[i].time))
            if error > worstError {
                worst = i
                worstError = error
            }
        }
        if worstError > tolerance {
            keep[worst] = true
            spans.append((a, worst))
            spans.append((worst, b))
        }
    }
    return points.indices.filter { keep[$0] }.map { points[$0] }
}

private func lerp(_ a: AutomationPoint, _ b: AutomationPoint, at t: MediaTime) -> Float {
    let span = (b.time - a.time).seconds
    guard span > 0 else { return b.value }
    let f = Float((t - a.time).seconds / span)
    return a.value + (b.value - a.value) * f
}

// MARK: - Playback envelope

extension Project {
    /// The level that actually plays for `target` across the whole sequence, as breakpoints
    /// to ramp linearly between: static levels (each clip's own, or the music fader), recorded
    /// passes, and the glides joining them. Two points at the same time are a step.
    /// Empty when there is nothing to play (no clips, or no music).
    public func levelEnvelope(for target: AutomationTarget) -> [AutomationPoint] {
        let base = staticLevels(for: target)
        guard !base.isEmpty else { return [] }
        let lane = lane(for: target)
        let end = duration
        let glide = AutomationLane.glide
        let cuts = base.dropFirst().map(\.start)

        // Glides stay inside a clip, so one clip's curve never eases into the next.
        /// A cut between the end of a pass at `a` and the asked-for side of `t`.
        func cutAfter(_ a: MediaTime, before t: MediaTime, fromLeft: Bool) -> Bool {
            cuts.contains { a <= $0 && (fromLeft ? $0 < t : $0 <= t) }
        }
        /// A cut between the asked-for side of `t` and the start of a pass at `b`.
        func cutBefore(_ b: MediaTime, after t: MediaTime, fromLeft: Bool) -> Bool {
            cuts.contains { $0 <= b && (fromLeft ? t <= $0 : t < $0) }
        }

        func baseLevel(at t: MediaTime, fromLeft: Bool) -> Float {
            let step = base.last { fromLeft ? $0.start < t : $0.start <= t } ?? base[0]
            return step.value
        }

        func level(at t: MediaTime, fromLeft: Bool) -> Float {
            // A recorded pass on the asked-for side of `t`.
            let segment = lane.segments.first {
                fromLeft ? $0.start < t && t <= $0.end : $0.start <= t && t < $0.end
            }
            if let segment { return segment.value(at: t) }
            // A glide into or out of the nearest pass, within the same clip.
            let out = lane.segments.last {
                $0.end <= t && t < $0.end + glide && !cutAfter($0.end, before: t, fromLeft: fromLeft)
            }
            let into = lane.segments.first {
                $0.start - glide < t && t <= $0.start && !cutBefore($0.start, after: t, fromLeft: fromLeft)
            }
            let useOut: Bool
            switch (out, into) {
            case (.some(let o), .some(let i)): useOut = (t - o.end) <= (i.start - t)
            case (.some, nil): useOut = true
            case (nil, .some): useOut = false
            case (nil, nil): return baseLevel(at: t, fromLeft: fromLeft)
            }
            if useOut, let o = out {
                let to = AutomationPoint(time: o.end + glide, value: baseLevel(at: o.end, fromLeft: true))
                return lerp(o.points[o.points.count - 1], to, at: t)
            } else if let i = into {
                let from = AutomationPoint(
                    time: i.start - glide, value: baseLevel(at: i.start, fromLeft: false))
                return lerp(from, i.points[0], at: t)
            }
            return baseLevel(at: t, fromLeft: fromLeft)
        }

        var times = Set(base.map(\.start))
        times.insert(.zero)
        times.insert(end)
        for segment in lane.segments {
            for point in segment.points { times.insert(point.time) }
            times.insert(segment.start - glide)
            times.insert(segment.end + glide)
        }
        var envelope: [AutomationPoint] = []
        for t in times.filter({ $0 >= .zero && $0 <= end }).sorted() {
            let left = level(at: t, fromLeft: true)
            let right = level(at: t, fromLeft: false)
            if t > .zero { envelope.append(AutomationPoint(time: t, value: left)) }
            if t < end, t == .zero || right != left { envelope.append(AutomationPoint(time: t, value: right)) }
        }
        return envelope
    }

    /// Static levels as steps: each takes over at `start` and holds until the next.
    private func staticLevels(for target: AutomationTarget) -> [(start: MediaTime, value: Float)] {
        guard !clips.isEmpty else { return [] }
        switch target {
        case .clipAudio:
            return SequenceMap(project: self).entries.compactMap { entry in
                clip(id: entry.clipID).map { (entry.compositionRange.start, $0.volume) }
            }
        case .music:
            guard let music = referenceAudio else { return [] }
            return [(.zero, music.volume)]
        }
    }
}
