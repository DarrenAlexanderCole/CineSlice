import Foundation

/// Maps between the four time domains used by the editor:
///
/// - **source time**: position inside an imported file (what `TimelineClip.sourceRange` stores)
/// - **clip-local time**: offset from the clip's first frame on the composition timeline
/// - **composition time**: position in the assembled sequence (what the preview player reports)
/// - **audio-reference time**: position inside the reference track
///   (`composition time - AudioTrack.offset`; see `MusicPlacement` for where it's audible)
///
/// source = sourceRange.start + clipLocal × speed
/// composition = entry.start + clipLocal
/// audio = composition − offset
public struct SequenceMap: Sendable {
    public struct Entry: Hashable, Sendable {
        public let clipID: UUID
        public let index: Int
        public let compositionRange: MediaTimeRange
        public let sourceStart: MediaTime
        public let speed: Double
    }

    public let entries: [Entry]
    public let duration: MediaTime
    /// `AudioTrack.offset` of the reference music, or nil when there's none.
    public let referenceOffset: MediaTime?

    public init(project: Project) {
        referenceOffset = project.referenceAudio?.offset
        var cursor = MediaTime.zero
        var built: [Entry] = []
        for (i, clip) in project.clips.enumerated() {
            let d = clip.compositionDuration
            built.append(
                Entry(
                    clipID: clip.id, index: i,
                    compositionRange: MediaTimeRange(start: cursor, duration: d),
                    sourceStart: clip.sourceRange.start, speed: clip.speed))
            cursor += d
        }
        entries = built
        duration = cursor
    }

    /// The clip under a composition time. The very end of the sequence maps to the last clip.
    public func entry(at compositionTime: MediaTime) -> Entry? {
        if let hit = entries.first(where: { $0.compositionRange.contains(compositionTime) }) { return hit }
        if let last = entries.last, compositionTime >= last.compositionRange.end { return last }
        return entries.first
    }

    public func entry(for clipID: UUID) -> Entry? { entries.first { $0.clipID == clipID } }

    public func compositionStart(of clipID: UUID) -> MediaTime? { entry(for: clipID)?.compositionRange.start }

    public func sourceTime(atComposition t: MediaTime) -> (clipID: UUID, sourceTime: MediaTime)? {
        guard let e = entry(at: t) else { return nil }
        let local = (t - e.compositionRange.start).clamped(to: .zero, e.compositionRange.duration)
        let scaledLocal = e.speed == 1 ? local : local.scaled(by: e.speed)
        return (e.clipID, e.sourceStart + scaledLocal)
    }

    public func compositionTime(clipID: UUID, sourceTime: MediaTime) -> MediaTime? {
        guard let e = entry(for: clipID) else { return nil }
        let sourceLocal = sourceTime - e.sourceStart
        let local = e.speed == 1 ? sourceLocal : sourceLocal.scaled(by: 1 / e.speed)
        return e.compositionRange.start + local.clamped(to: .zero, e.compositionRange.duration)
    }

    // MARK: Audio-reference time

    /// Position in the reference song heard at composition time `t` (negative or past
    /// the song's end means no music there). nil without reference music.
    public func audioTime(atComposition t: MediaTime) -> MediaTime? { referenceOffset.map { t - $0 } }

    public func compositionTime(atAudio t: MediaTime) -> MediaTime? { referenceOffset.map { t + $0 } }
}
