import Foundation

// MARK: - Reference music placement

/// Where the reference music is heard in the sequence.
///
/// audio-reference time = composition time − `AudioTrack.offset`
///
/// Music is trimmed to the sequence: it never starts before composition 0 or
/// plays past the last frame of video.
public struct MusicPlacement: Equatable, Sendable {
    /// The part of the composition timeline where music plays.
    public let compositionRange: MediaTimeRange
    /// The position in the music file that plays at `compositionRange.start`.
    public let audioStart: MediaTime

    /// nil when the music and the sequence don't overlap at all.
    public init?(track: AudioTrack, sequenceDuration: MediaTime) {
        let start = max(MediaTime.zero, track.offset)
        let end = min(sequenceDuration, track.offset + track.duration)
        guard end > start else { return nil }
        compositionRange = MediaTimeRange(start: start, end: end)
        audioStart = start - track.offset
    }
}

extension AudioTrack {
    /// Keeps at least `minimumClipDuration` of music overlapping the sequence, so
    /// the music can't be dragged out of reach.
    public func clampedOffset(_ proposed: MediaTime, sequenceDuration: MediaTime) -> MediaTime {
        let overlap = min(minimumClipDuration, duration)
        let lower = MediaTime.zero - (duration - overlap)
        let upper = max(lower, sequenceDuration - min(overlap, sequenceDuration))
        return proposed.clamped(to: lower, upper)
    }
}

// MARK: - Loop region

extension LoopRange {
    /// The loop fitted inside a sequence of `duration`, or nil if the sequence is too short to loop.
    public func clamped(toSequence duration: MediaTime) -> LoopRange? {
        guard duration >= minimumClipDuration else { return nil }
        let start = range.start.clamped(to: .zero, duration - minimumClipDuration)
        let end = range.end.clamped(to: start + minimumClipDuration, duration)
        return LoopRange(range: MediaTimeRange(start: start, end: end), isEnabled: isEnabled)
    }
}

extension LoopRange {
    /// Loop In at `t`: keeps the current end when it's still after `t`, otherwise loops to the sequence end.
    public static func settingStart(
        _ t: MediaTime, of current: LoopRange?, sequenceDuration duration: MediaTime
    ) -> LoopRange? {
        guard duration >= minimumClipDuration else { return nil }
        let start = t.clamped(to: .zero, duration - minimumClipDuration)
        var end = duration
        if let current, current.range.end >= start + minimumClipDuration { end = current.range.end }
        return LoopRange(range: MediaTimeRange(start: start, end: end)).clamped(toSequence: duration)
    }

    /// Loop Out at `t`: keeps the current start when it's still before `t`, otherwise loops from 0.
    public static func settingEnd(
        _ t: MediaTime, of current: LoopRange?, sequenceDuration duration: MediaTime
    ) -> LoopRange? {
        guard duration >= minimumClipDuration else { return nil }
        let end = t.clamped(to: minimumClipDuration, duration)
        var start = MediaTime.zero
        if let current, current.range.start <= end - minimumClipDuration { start = current.range.start }
        return LoopRange(range: MediaTimeRange(start: start, end: end)).clamped(toSequence: duration)
    }
}

// MARK: - Export sound policy

extension Project {
    /// The policy export uses: the user's choice, otherwise Silent when there's reference music
    /// (so the licensed song can be added in Instagram) and clip sound when there isn't.
    /// "Clips + music" without music is just clip sound.
    public var exportSoundPolicy: SoundPolicy {
        let hasMusic = referenceAudio != nil
        let chosen = exportSettings.soundPolicy ?? (hasMusic ? .silent : .clipsOnly)
        return chosen == .clipsAndMusic && !hasMusic ? .clipsOnly : chosen
    }
}

// MARK: - Music sync note

/// Where the reference song sits against the video, for lining up the licensed
/// copy inside Instagram by hand. Written as a JSON sidecar next to each export.
public struct MusicSyncNote: Codable, Equatable, Sendable {
    public var referenceFilename: String
    /// Composition time of song 0 (negative: the song starts before the video).
    public var offset: MediaTime
    public var offsetSeconds: Double
    public var compositionDurationSeconds: Double
    /// Song position heard on the first frame.
    public var songStartSeconds: Double
    public var soundPolicy: SoundPolicy
    public var exportFilename: String?
    /// e.g. "In Instagram, start the song at 0:12.40."
    public var instruction: String
    public var caveat: String

    public static let caveatText =
        "Instagram doesn't let apps set where its music starts, so match it by hand there. "
        + "It may be off by a fraction of a second; check it before posting."

    /// nil when the project has no reference music.
    public init?(project: Project, exportFilename: String? = nil) {
        guard let music = project.referenceAudio else { return nil }
        referenceFilename = music.originalFilename ?? music.fileName
        offset = music.offset
        offsetSeconds = music.offset.seconds
        compositionDurationSeconds = project.duration.seconds
        songStartSeconds = max(0, -music.offset.seconds)
        soundPolicy = project.exportSoundPolicy
        self.exportFilename = exportFilename
        if music.offset <= .zero {
            instruction = "In Instagram, start the song at \(Self.clock(songStartSeconds))."
        } else {
            instruction =
                "In Instagram, start the song at 0:00.00. In this edit it comes in "
                + "\(Self.clock(music.offset.seconds)) after the video starts, but Instagram plays music from the first frame."
        }
        caveat = Self.caveatText
    }

    /// m:ss.cc, the way music apps show song positions.
    public static func clock(_ seconds: Double) -> String {
        let centis = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", centis / 6000, (centis / 100) % 60, centis % 100)
    }

    public var jsonData: Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}

// MARK: - Waveform

/// Peak amplitudes (0…1) at a fixed rate, computed once per music file and cached.
public struct Waveform: Equatable, Sendable {
    public let peaksPerSecond: Double
    public let peaks: [Float]

    public init(peaksPerSecond: Double, peaks: [Float]) {
        self.peaksPerSecond = peaksPerSecond
        self.peaks = peaks
    }

    /// Max peak in each of `buckets` equal slices of [from, to) in audio time.
    /// Times outside the audio read as silence.
    public func envelope(from: MediaTime, to: MediaTime, buckets: Int) -> [Float] {
        guard buckets > 0, to > from, !peaks.isEmpty else { return Array(repeating: 0, count: max(0, buckets)) }
        let startIndex = from.seconds * peaksPerSecond
        let span = (to - from).seconds * peaksPerSecond / Double(buckets)
        return (0..<buckets).map { b in
            let lo = Int((startIndex + Double(b) * span).rounded(.down))
            let hi = max(lo + 1, Int((startIndex + Double(b + 1) * span).rounded(.up)))
            let a = max(lo, 0)
            let z = min(hi, peaks.count)
            guard a < z else { return 0 }
            return peaks[a..<z].max() ?? 0
        }
    }

    // Binary cache: "PIWF", version, peaksPerSecond, count, Float32 peaks (little-endian).
    private static let magic: UInt32 = 0x4657_4950  // "PIWF"
    private static let version: UInt32 = 1

    public var data: Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(Waveform.magic.littleEndian)
        put(Waveform.version.littleEndian)
        put(peaksPerSecond.bitPattern.littleEndian)
        put(UInt64(peaks.count).littleEndian)
        for p in peaks { put(p.bitPattern.littleEndian) }
        return d
    }

    public init?(data: Data) {
        var cursor = 0
        func take<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard cursor + size <= data.count else { return nil }
            var v: T = 0
            withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: data[(data.startIndex + cursor)...].prefix(size)) }
            cursor += size
            return T(littleEndian: v)
        }
        guard take(UInt32.self) == Waveform.magic, take(UInt32.self) == Waveform.version,
            let rateBits = take(UInt64.self), let count = take(UInt64.self),
            data.count - cursor == Int(count) * 4
        else { return nil }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let bits = take(UInt32.self) else { return nil }
            peaks.append(Float(bitPattern: bits))
        }
        self.peaksPerSecond = Double(bitPattern: rateBits)
        self.peaks = peaks
    }
}
