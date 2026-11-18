import Foundation

// MARK: - Where the reference music came from

/// How the project's reference track was made. A Quick Click or Billboards guide is rendered to an
/// ordinary audio file, so playback, export, waveform and alignment treat it like any song; this
/// records how to make it again when it's edited.
public struct MusicReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A song or a video's sound from the phone.
        case myMusic
        /// A click guide at a chosen tempo.
        case quickClick
        /// A song named for Instagram, its rhythm tapped along by hand.
        case billboards
    }

    public var kind: Kind
    public var click: ClickGuide?
    public var rhythm: TapRhythm?
    public var song: SongIdentity?

    public init(kind: Kind, click: ClickGuide? = nil, rhythm: TapRhythm? = nil, song: SongIdentity? = nil) {
        self.kind = kind
        self.click = click
        self.rhythm = rhythm
        self.song = song
    }
}

/// The song to add in Instagram after export, typed in by hand. CineSlice never fetches or
/// copies it; this only labels the guide and goes into the handoff.
public struct SongIdentity: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    /// Which part of the song, e.g. "the chorus".
    public var section: String
    /// Where in the song the tapping began, when known: then the handoff can give an exact start.
    public var tappedFrom: MediaTime?

    public init(title: String = "", artist: String = "", section: String = "", tappedFrom: MediaTime? = nil) {
        self.title = title
        self.artist = artist
        self.section = section
        self.tappedFrom = tappedFrom
    }

    public var isEmpty: Bool {
        [title, artist, section].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "Title by Artist", "Title", or nil.
    public var displayName: String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = artist.trimmingCharacters(in: .whitespaces)
        switch (t.isEmpty, a.isEmpty) {
        case (false, false): return "\u{201C}\(t)\u{201D} by \(a)"
        case (false, true): return "\u{201C}\(t)\u{201D}"
        case (true, false): return "a song by \(a)"
        case (true, true): return nil
        }
    }
}

/// One sound in a guide, in the guide's own time (beat one at 0).
public struct GuideClick: Hashable, Sendable {
    public enum Weight: Sendable { case accent, beat, subdivision }
    public var time: MediaTime
    public var weight: Weight

    public init(time: MediaTime, weight: Weight) {
        self.time = time
        self.weight = weight
    }
}

/// Clicks are placed on a 48 kHz grid: finer than any frame, exact in `MediaTime`.
let guideTimescale: Int32 = 48_000

func guideTime(seconds: Double) -> MediaTime {
    MediaTime(value: Int64((seconds * Double(guideTimescale)).rounded()), timescale: guideTimescale)
}

public enum Subdivision: String, Codable, CaseIterable, Sendable {
    case quarter, eighth

    /// Clicks per beat.
    public var perBeat: Int { self == .quarter ? 1 : 2 }
}

/// Time signatures a guide can count in. In 6/8 the counted pulse is the eighth note: six to the
/// bar, felt in two (1 and 4).
public enum Meter: String, Codable, CaseIterable, Sendable {
    case twoFour = "2/4"
    case threeFour = "3/4"
    case fourFour = "4/4"
    case sixEight = "6/8"

    public var beatsPerBar: Int {
        switch self {
        case .twoFour: 2
        case .threeFour: 3
        case .fourFour: 4
        case .sixEight: 6
        }
    }

    /// Compound time: beats grouped in threes, the second group's first beat a lighter accent.
    public var isCompound: Bool { self == .sixEight }
}

/// A metronome: tempo, time signature, subdivision and an accented downbeat. Beat one sits at
/// the guide's time 0; the track's offset places it on the timeline.
public struct ClickGuide: Codable, Hashable, Sendable {
    public static let tempoRange: ClosedRange<Double> = 30...300

    /// Counted pulses per minute (eighth notes in 6/8).
    public var bpm: Double
    public var meter: Meter
    /// Quarter or eighth clicks; compound meters already count eighths, so they ignore it.
    public var subdivision: Subdivision
    public var accentsDownbeat: Bool

    public init(
        bpm: Double = 120, meter: Meter = .fourFour, subdivision: Subdivision = .quarter, accentsDownbeat: Bool = true
    ) {
        self.bpm = min(max(bpm, Self.tempoRange.lowerBound), Self.tempoRange.upperBound)
        self.meter = meter
        self.subdivision = subdivision
        self.accentsDownbeat = accentsDownbeat
    }

    enum CodingKeys: String, CodingKey {
        case bpm, meter, subdivision, accentsDownbeat
        /// Before meters: a count of beats, always 4.
        case beatsPerBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        let beats = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar)
        meter =
            try c.decodeIfPresent(Meter.self, forKey: .meter)
            ?? Meter.allCases.first { $0.beatsPerBar == beats && !$0.isCompound } ?? .fourFour
        subdivision = try c.decodeIfPresent(Subdivision.self, forKey: .subdivision) ?? .quarter
        accentsDownbeat = try c.decodeIfPresent(Bool.self, forKey: .accentsDownbeat) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(meter, forKey: .meter)
        try c.encode(subdivision, forKey: .subdivision)
        try c.encode(accentsDownbeat, forKey: .accentsDownbeat)
    }

    public var beatsPerBar: Int { meter.beatsPerBar }

    /// Start of beat `n` (0 is beat one), exact to the 48 kHz grid.
    public func beatTime(_ n: Int) -> MediaTime { guideTime(seconds: Double(n) * 60 / bpm) }

    public var barDuration: MediaTime { beatTime(beatsPerBar) }

    /// Every click from beat one up to (not including) `duration`.
    public func clicks(upTo duration: MediaTime) -> [GuideClick] {
        var clicks: [GuideClick] = []
        let perBeat = meter.isCompound ? 1 : subdivision.perBeat
        var k = 0
        while true {
            let time = guideTime(seconds: Double(k) * 60 / bpm / Double(perBeat))
            guard time < duration else { break }
            let beat = k / perBeat
            let inBar = beat % beatsPerBar
            let weight: GuideClick.Weight
            if k % perBeat != 0 {
                weight = .subdivision
            } else if inBar == 0 {
                weight = accentsDownbeat ? .accent : .beat
            } else if meter.isCompound {
                // 6/8: beat 4 starts the second group; the rest are the lighter eighths between.
                weight = inBar == 3 ? .beat : .subdivision
            } else {
                weight = .beat
            }
            clicks.append(GuideClick(time: time, weight: weight))
            k += 1
        }
        return clicks
    }
}

/// How tapped events sit against the beat grid. The taps themselves are never rewritten, so any
/// choice can be undone by choosing another.
public enum Quantization: String, Codable, CaseIterable, Sendable {
    /// Exactly as tapped.
    case human
    /// Halfway to the nearest grid line: tidier, still played.
    case light
    /// On the nearest grid line.
    case grid
}

/// Taps captured along to a song played elsewhere. Tempo mode keeps only the steady pulse (its
/// BPM drives a click guide); rhythm mode keeps every tap where it fell, as the guide's events.
public struct TapRhythm: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case tempo, rhythm }

    public struct Tap: Codable, Hashable, Sendable {
        /// From the first tap.
        public var time: MediaTime
        public var accent: Bool

        public init(time: MediaTime, accent: Bool = false) {
            self.time = time
            self.accent = accent
        }
    }

    public var mode: Mode
    /// As captured; quantizing works on a copy.
    public var taps: [Tap]
    /// The grid for quantizing and repeating, and the tempo-mode click: estimated, then correctable.
    public var grid: ClickGuide
    public var quantization: Quantization
    /// Rhythm mode: play the tapped pattern over and over (whole bars), only when chosen.
    public var repeats: Bool

    public init(
        mode: Mode, taps: [Tap] = [], grid: ClickGuide = ClickGuide(), quantization: Quantization = .human,
        repeats: Bool = false
    ) {
        self.mode = mode
        self.taps = taps
        self.grid = grid
        self.quantization = quantization
        self.repeats = repeats
    }

    /// The taps placed on the grid as chosen, still in order.
    public var placedTaps: [Tap] {
        guard quantization != .human else { return taps }
        let step = 60 / grid.bpm / Double(grid.subdivision.perBeat)
        return taps.map { tap in
            let t = tap.time.seconds
            let snapped = (t / step).rounded() * step
            let placed = quantization == .grid ? snapped : (t + snapped) / 2
            return Tap(time: guideTime(seconds: max(0, placed)), accent: tap.accent)
        }
    }

    /// The pattern's length: whole bars covering every tap.
    public var patternDuration: MediaTime {
        guard let last = placedTaps.last else { return grid.barDuration }
        let bars = Int((last.time.seconds / grid.barDuration.seconds).rounded(.down)) + 1
        return grid.beatTime(bars * grid.beatsPerBar)
    }

    /// The guide's sounds up to `duration`: the steady click in tempo mode; in rhythm mode the
    /// taps (accented ones louder), repeated bar for bar when `repeats` is on.
    public func clicks(upTo duration: MediaTime) -> [GuideClick] {
        switch mode {
        case .tempo:
            return grid.clicks(upTo: duration)
        case .rhythm:
            let pattern = placedTaps.map { GuideClick(time: $0.time, weight: $0.accent ? .accent : .beat) }
            guard repeats, !pattern.isEmpty else { return pattern.filter { $0.time < duration } }
            var clicks: [GuideClick] = []
            var start = MediaTime.zero
            let length = patternDuration
            while start < duration {
                for click in pattern {
                    let time = start + click.time
                    if time < duration { clicks.append(GuideClick(time: time, weight: click.weight)) }
                }
                start = start + length
            }
            return clicks
        }
    }
}

// MARK: - Tap capture

/// Turns taps (seconds on a monotonic clock, e.g. touch timestamps) into a tempo and a rhythm.
/// A long pause starts over; taps too close together to be meant are dropped as bounces.
public struct TapCapture: Sendable {
    /// Longer than this between taps starts a new take (tempo taps; rhythm takes allow longer).
    public static let restartGap = 2.5
    public static let rhythmRestartGap = 6.0
    /// Closer than this to the previous tap is a bounce, not a tap (rhythm mode).
    public static let bounce = 0.06
    /// Tempo taps further apart or closer than these aren't a pulse (30–300 BPM).
    static let pulseRange: ClosedRange<Double> =
        (60 / ClickGuide.tempoRange.upperBound)...(60 / ClickGuide.tempoRange.lowerBound)
    /// How many recent intervals the tempo is taken from.
    static let window = 8

    /// Seconds of each kept tap, on the caller's clock.
    public private(set) var times: [Double] = []
    public private(set) var accents: [Bool] = []
    public let restartAfter: Double

    public init(restartAfter: Double = TapCapture.restartGap) {
        self.restartAfter = restartAfter
    }

    /// Adds a tap; returns false when it was dropped as a bounce. A tap after a long pause
    /// starts a new take with it as the first.
    @discardableResult
    public mutating func tap(at seconds: Double, accent: Bool = false) -> Bool {
        if let last = times.last {
            let gap = seconds - last
            if gap < Self.bounce { return false }
            if gap > restartAfter { reset() }
        }
        times.append(seconds)
        accents.append(accent)
        return true
    }

    public mutating func reset() {
        times = []
        accents = []
    }

    /// The tempo from the recent steady intervals: the median, after dropping ones that are
    /// implausible or far from the rest (a missed or doubled tap). Nil until there are three taps.
    public var bpm: Double? {
        let intervals = zip(times, times.dropFirst()).map { $1 - $0 }.suffix(Self.window)
            .filter { Self.pulseRange.contains($0) }
        guard intervals.count >= 2 else { return nil }
        let median = Self.median(Array(intervals))
        let steady = intervals.filter { abs($0 - median) / median < 0.3 }
        guard !steady.isEmpty else { return nil }
        return 60 / Self.median(steady)
    }

    /// The take as rhythm taps from its first tap, in `MediaTime`.
    public var rhythm: [TapRhythm.Tap] {
        guard let first = times.first else { return [] }
        return zip(times, accents).map { TapRhythm.Tap(time: guideTime(seconds: $0 - first), accent: $1) }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
