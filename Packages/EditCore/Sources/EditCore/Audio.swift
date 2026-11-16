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
    public func audioTime(atComposition t: MediaTime) -> MediaTime { t - offset }
    public func compositionTime(atAudio t: MediaTime) -> MediaTime { t + offset }

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

// MARK: - Export sound policy

/// What the exported file contains. Preview always plays the full mix.
public enum SoundPolicy: String, CaseIterable, Sendable {
    case clipsAndMusic
    case clipsOnly
    case musicOnly
    /// For attaching a licensed song inside Instagram afterwards.
    case silent

    public var includesClipAudio: Bool { self == .clipsAndMusic || self == .clipsOnly }
    public var includesMusic: Bool { self == .clipsAndMusic || self == .musicOnly }
}

extension ExportSettings {
    public var soundPolicy: SoundPolicy {
        get {
            switch (includeClipAudio, includeMusic) {
            case (true, true): return .clipsAndMusic
            case (true, false): return .clipsOnly
            case (false, true): return .musicOnly
            case (false, false): return .silent
            }
        }
        set {
            includeClipAudio = newValue.includesClipAudio
            includeMusic = newValue.includesMusic
        }
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
