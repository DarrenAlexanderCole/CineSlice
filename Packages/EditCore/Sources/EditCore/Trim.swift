import Foundation

// MARK: - Trim at a time (LIGHTBOX)

/// Which end a trim takes off: everything before the time, or everything after it.
public enum TrimEdge: Sendable {
    case start, end
}

/// What a trim works on: a clip of the sequence, a stacked clip or a sound.
public enum TrimTarget: Hashable, Sendable {
    case clip(UUID)
    case layerClip(UUID)
    case sound(UUID)
}

/// Cuts a clip, stacked clip or sound back to a composition time, taking off its start (up to
/// the time) or its end (from the time). The part kept stays exactly where it played, so
/// everything else stays put and a gap opens where the trimmed part was; on the sequence the
/// clips after it don't close up. The part kept must be at least `minimumClipDuration`.
/// Fades are kept to what's left of a sound. The source file is untouched, so a later trim
/// on the upright Trim page can bring the rest back.
public struct TrimAtCommand: EditingCommand {
    public let target: TrimTarget
    public let edge: TrimEdge
    public let time: MediaTime

    public init(target: TrimTarget, edge: TrimEdge, time: MediaTime) {
        self.target = target
        self.edge = edge
        self.time = time
    }

    public var actionName: String { edge == .start ? "Trim Start" : "Trim End" }

    /// Whether trimming `range` at `time` takes something off and keeps enough.
    public static func canTrim(_ range: MediaTimeRange, edge: TrimEdge, at time: MediaTime) -> Bool {
        guard time > range.start, time < range.end else { return false }
        let kept = edge == .start ? range.end - time : time - range.start
        return kept >= minimumClipDuration
    }

    /// Whether `target` can be trimmed at `time` in `project`.
    public static func canTrim(_ target: TrimTarget, edge: TrimEdge, at time: MediaTime, in project: Project) -> Bool {
        switch target {
        case .clip(let id):
            let map = SequenceMap(project: project)
            guard let entry = map.entry(for: id), let clip = project.clip(id: id),
                canTrim(entry.compositionRange, edge: edge, at: time),
                let hit = map.sourceTime(atComposition: time), hit.clipID == id
            else { return false }
            // At a speed other than 1 the composition and source lengths differ; keep enough source.
            let kept =
                edge == .start ? clip.sourceRange.end - hit.sourceTime : hit.sourceTime - clip.sourceRange.start
            return kept >= minimumClipDuration
        case .layerClip(let id):
            return project.layerClip(id: id).map { canTrim($0.timelineRange, edge: edge, at: time) } ?? false
        case .sound(let id):
            return project.sound(id: id).map { canTrim($0.timelineRange, edge: edge, at: time) } ?? false
        }
    }

    public func apply(to project: inout Project) throws {
        guard Self.canTrim(target, edge: edge, at: time, in: project) else {
            switch target {
            case .clip(let id) where project.clip(id: id) == nil: throw EditError.clipNotFound
            case .layerClip(let id) where project.layerClip(id: id) == nil: throw EditError.clipNotFound
            case .sound(let id) where project.sound(id: id) == nil: throw EditError.clipNotFound
            default: throw EditError.invalidRange
            }
        }
        switch target {
        case .clip(let id):
            guard let cut = SequenceMap(project: project).sourceTime(atComposition: time)?.sourceTime else {
                throw EditError.invalidRange
            }
            typealias Item = (clip: TimelineClip, start: MediaTime)
            let items = SequencePlacement(project: project).items.map { item -> Item in
                guard item.clip.id == id else { return item }
                var clip = item.clip
                // The level curve is in source time, so it stays with the picture it belongs to.
                switch edge {
                case .start:
                    clip.sourceRange = MediaTimeRange(start: cut, end: clip.sourceRange.end)
                    return (clip, time)
                case .end:
                    clip.sourceRange = MediaTimeRange(start: clip.sourceRange.start, end: cut)
                    return (clip, item.start)
                }
            }
            project.setSequence(items)
        case .layerClip(let id):
            guard let at = project.layerLocation(id: id) else { throw EditError.clipNotFound }
            var clip = project.videoLayers[at.layer].clips[at.index]
            let cut = clip.clip.sourceRange.start + (time - clip.start)
            switch edge {
            case .start:
                clip.clip.sourceRange = MediaTimeRange(start: cut, end: clip.clip.sourceRange.end)
                clip.start = time
            case .end:
                clip.clip.sourceRange = MediaTimeRange(start: clip.clip.sourceRange.start, end: cut)
            }
            project.videoLayers[at.layer].clips[at.index] = clip
        case .sound(let id):
            guard let at = project.soundLocation(id: id) else { throw EditError.clipNotFound }
            var clip = project.soundTracks[at.track].clips[at.index]
            let cut = clip.sourceRange.start + (time - clip.start)
            switch edge {
            case .start:
                clip.sourceRange = MediaTimeRange(start: cut, end: clip.sourceRange.end)
                clip.start = time
            case .end:
                clip.sourceRange = MediaTimeRange(start: clip.sourceRange.start, end: cut)
            }
            clip.clampFades()
            project.soundTracks[at.track].clips[at.index] = clip
        }
    }
}
