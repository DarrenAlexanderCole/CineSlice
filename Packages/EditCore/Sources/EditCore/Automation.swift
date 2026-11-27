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
    /// The same for a curve drawn by finger, which wobbles more than a fader (3%).
    public static let drawnTolerance: Float = 0.03

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

    // MARK: Point editing

    /// Closest two points may come in time, so a pass never folds back on itself.
    static let pointGap = MediaTime(value: 1, timescale: 600)

    /// Width of the flat pass a point added between passes starts as.
    static let newPassWidth = MediaTime(seconds: 1)

    /// Moves a point, held between its neighbours (and the passes either side) and inside `bounds`.
    mutating func movePoint(
        segment s: Int, point p: Int, to target: AutomationPoint, within bounds: MediaTimeRange
    ) -> Bool {
        guard segments.indices.contains(s), segments[s].points.indices.contains(p) else { return false }
        let points = segments[s].points
        var lower = bounds.start
        var upper = bounds.end
        if p > 0 {
            lower = points[p - 1].time + Self.pointGap
        } else if s > 0 {
            lower = max(lower, segments[s - 1].end)
        }
        if p < points.count - 1 {
            upper = points[p + 1].time - Self.pointGap
        } else if s < segments.count - 1 {
            upper = min(upper, segments[s + 1].start)
        }
        guard upper >= lower else { return false }
        segments[s].points[p] = AutomationPoint(
            time: target.time.clamped(to: lower, upper), value: min(max(target.value, 0), 1))
        return true
    }

    /// Adds a point: inside a pass it bends the pass there; between passes it starts a short
    /// flat pass at that level, fitted to the gap and `bounds`.
    mutating func addPoint(_ point: AutomationPoint, within bounds: MediaTimeRange) -> Bool {
        let value = min(max(point.value, 0), 1)
        let t = point.time
        guard t >= bounds.start, t <= bounds.end else { return false }
        if let s = segments.firstIndex(where: { $0.start <= t && t <= $0.end }) {
            let points = segments[s].points
            if let same = points.firstIndex(where: { $0.time == t }) {
                segments[s].points[same].value = value
                return true
            }
            let i = points.firstIndex { $0.time > t } ?? points.count
            guard t - points[i - 1].time >= Self.pointGap, points[i].time - t >= Self.pointGap else { return false }
            segments[s].points.insert(AutomationPoint(time: t, value: value), at: i)
            return true
        }
        let half = Self.newPassWidth.scaled(by: 0.5)
        let before = segments.last { $0.end <= t }?.end ?? bounds.start
        let after = segments.first { $0.start >= t }?.start ?? bounds.end
        let start = max(t - half, max(before, bounds.start))
        let end = min(t + half, min(after, bounds.end))
        guard end - start >= Self.pointGap else { return false }
        segments.append(
            AutomationSegment(points: [
                AutomationPoint(time: start, value: value), AutomationPoint(time: end, value: value),
            ]))
        segments.sort { $0.start < $1.start }
        return true
    }

    /// Removes a point; a pass left with one point goes entirely.
    mutating func removePoint(segment s: Int, point p: Int) -> Bool {
        guard segments.indices.contains(s), segments[s].points.indices.contains(p) else { return false }
        segments[s].points.remove(at: p)
        if segments[s].points.count < 2 { segments.remove(at: s) }
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
                cursor += clip.gap
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
            cursor += clips[i].gap
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
    /// `tolerance` removed. nil if fewer than two distinct times remain.
    public init?(
        recorded samples: [AutomationPoint], sequenceDuration: MediaTime,
        tolerance: Float = AutomationLane.tolerance
    ) {
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
        self.init(points: simplify(points, tolerance: tolerance))
    }
}

/// A finger's samples in time order with each level averaged with up to two neighbours either
/// side, so wobble doesn't survive as jagged points. The ends keep their levels.
func smoothed(_ samples: [AutomationPoint]) -> [AutomationPoint] {
    let sorted = samples.sorted { $0.time < $1.time }
    guard sorted.count > 2 else { return sorted }
    return sorted.indices.map { i in
        guard i > 0, i < sorted.count - 1 else { return sorted[i] }
        let reach = min(2, i, sorted.count - 1 - i)
        let window = sorted[(i - reach)...(i + reach)]
        return AutomationPoint(time: sorted[i].time, value: window.map(\.value).reduce(0, +) / Float(window.count))
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
    ///
    /// `gain` scales clip sound clip by clip (a split clip's voice or scene level), stepping at
    /// the cuts; the music ignores it.
    public func levelEnvelope(
        for target: AutomationTarget, gain: ((TimelineClip) -> Float)? = nil
    ) -> [AutomationPoint] {
        let base = staticLevels(for: target)
        let gains: [(start: MediaTime, value: Float)] =
            target == .clipAudio
            ? SequenceMap(project: self).entries.compactMap { entry in
                clip(id: entry.clipID).map { (entry.compositionRange.start, gain?($0) ?? 1) }
            }
            : []
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
        func gainAt(_ t: MediaTime, fromLeft: Bool) -> Float {
            guard let first = gains.first else { return 1 }
            return (gains.last { fromLeft ? $0.start < t : $0.start <= t } ?? first).value
        }

        var envelope: [AutomationPoint] = []
        for t in times.filter({ $0 >= .zero && $0 <= end }).sorted() {
            let left = level(at: t, fromLeft: true) * gainAt(t, fromLeft: true)
            let right = level(at: t, fromLeft: false) * gainAt(t, fromLeft: false)
            if t > .zero { envelope.append(AutomationPoint(time: t, value: left)) }
            if t < end, t == .zero || right != left { envelope.append(AutomationPoint(time: t, value: right)) }
        }
        return Self.applyingFades(envelope, regions: fadeRegions(for: target))
    }

    /// Where the song is heard: from where it starts (or 0) to its end or the sequence's,
    /// whichever comes first. Empty if it ends before the sequence starts or starts after it ends.
    public func musicHeardRange(_ music: AudioTrack) -> MediaTimeRange {
        let song = music.timelineRange
        return MediaTimeRange(start: song.start, end: max(min(song.end, duration), song.start))
    }

    /// Where `target` plays with a fade: each clip with one, or the song where it's heard.
    func fadeRegions(for target: AutomationTarget) -> [FadeRegion] {
        switch target {
        case .clipAudio:
            let map = SequenceMap(project: self)
            return zip(clips, map.entries).compactMap { clip, entry in
                FadeRegion(range: entry.compositionRange, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
            }
        case .music:
            guard let music = referenceAudio else { return [] }
            return [FadeRegion(range: musicHeardRange(music), fadeIn: music.fadeIn, fadeOut: music.fadeOut)]
                .compactMap { $0 }
        }
    }

    /// `envelope` scaled by the fades: each rises from 0 at its region's start and falls to 0 at
    /// its end. Steps where envelope or fade meet stay steps; where both ramp at once the product
    /// curves, so it's followed in short pieces.
    static func applyingFades(_ envelope: [AutomationPoint], regions: [FadeRegion]) -> [AutomationPoint] {
        guard !regions.isEmpty, let first = envelope.first, let last = envelope.last else { return envelope }

        // Two points at one time are a step: the left side reads the first, the right the second.
        func level(at t: MediaTime, fromLeft: Bool) -> Float {
            for (a, b) in zip(envelope, envelope.dropFirst()) where b.time > a.time {
                if fromLeft ? (a.time < t && t <= b.time) : (a.time <= t && t < b.time) { return lerp(a, b, at: t) }
            }
            return t <= first.time ? first.value : last.value
        }

        var times = Set(envelope.map(\.time))
        let pieces = 6
        for region in regions {
            let ramps = [
                (region.range.start, region.range.start + region.fadeIn),
                (region.range.end - region.fadeOut, region.range.end),
            ]
            for (from, to) in ramps where to > from {
                for i in 0...pieces { times.insert(from + (to - from).scaled(by: Double(i) / Double(pieces))) }
            }
        }

        var faded: [AutomationPoint] = []
        for t in times.filter({ $0 >= first.time && $0 <= last.time }).sorted() {
            let left = level(at: t, fromLeft: true) * FadeRegion.gain(regions, at: t, fromLeft: true)
            let right = level(at: t, fromLeft: false) * FadeRegion.gain(regions, at: t, fromLeft: false)
            if t > first.time { faded.append(AutomationPoint(time: t, value: left)) }
            if t < last.time, t == first.time || right != left { faded.append(AutomationPoint(time: t, value: right)) }
        }
        return faded
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

/// A stretch of a lane that fades in from silence at its start and out to silence at its end.
struct FadeRegion {
    let range: MediaTimeRange
    let fadeIn: MediaTime
    let fadeOut: MediaTime

    /// nil when there's no fade. The fades are kept inside the range, never overlapping.
    init?(range: MediaTimeRange, fadeIn: MediaTime, fadeOut: MediaTime) {
        guard range.duration > .zero, fadeIn > .zero || fadeOut > .zero else { return nil }
        self.range = range
        self.fadeIn = min(max(fadeIn, .zero), range.duration)
        self.fadeOut = min(max(fadeOut, .zero), range.duration - self.fadeIn)
    }

    /// The fade's gain at `t`, 0…1, on the asked-for side; 1 outside every region.
    static func gain(_ regions: [FadeRegion], at t: MediaTime, fromLeft: Bool) -> Float {
        guard
            let region = regions.first(where: {
                fromLeft ? $0.range.start < t && t <= $0.range.end : $0.range.start <= t && t < $0.range.end
            })
        else { return 1 }
        var gain = 1.0
        if region.fadeIn > .zero, t < region.range.start + region.fadeIn {
            gain = (t - region.range.start).seconds / region.fadeIn.seconds
        }
        if region.fadeOut > .zero, t > region.range.end - region.fadeOut {
            gain = min(gain, (region.range.end - t).seconds / region.fadeOut.seconds)
        }
        return Float(min(max(gain, 0), 1))
    }
}
