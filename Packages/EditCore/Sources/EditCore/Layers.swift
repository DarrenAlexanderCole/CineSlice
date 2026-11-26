import Foundation

// MARK: - Video layers

/// A clip stacked on a video lane above the sequence, placed at a time: while it plays its
/// picture covers the lanes under it (a cutaway). It is picture only; the sequence's sound
/// carries on underneath. It keeps a `TimelineClip` for the source, range, framing and crop, at
/// normal speed; the clip's own gap, level and sound settings are unused here.
public struct LayerClip: Codable, Hashable, Identifiable, Sendable {
    public var clip: TimelineClip
    /// Where it starts on the composition timeline (never before 0).
    public var start: MediaTime

    public init(clip: TimelineClip, start: MediaTime) {
        var clip = clip
        clip.gap = .zero
        clip.speed = 1
        self.clip = clip
        self.start = max(start, .zero)
    }

    public var id: UUID { clip.id }

    /// Where it plays on the composition timeline.
    public var timelineRange: MediaTimeRange { MediaTimeRange(start: start, duration: clip.sourceRange.duration) }
}

/// One video lane above the sequence. Clips on a lane never overlap; a higher lane covers a
/// lower one.
public struct VideoLayer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Clips in time order.
    public var clips: [LayerClip]

    public init(id: UUID = UUID(), clips: [LayerClip] = []) {
        self.id = id
        self.clips = clips.sorted { $0.start < $1.start }
    }

    /// Whether `range` is clear of every clip here but `excluding`.
    public func fits(_ range: MediaTimeRange, excluding: UUID? = nil) -> Bool {
        clips.allSatisfy { clip in
            clip.id == excluding || clip.timelineRange.end <= range.start || clip.timelineRange.start >= range.end
        }
    }

    mutating func insert(_ clip: LayerClip) {
        let at = clips.firstIndex { $0.start > clip.start } ?? clips.count
        clips.insert(clip, at: at)
    }
}

extension Project {
    /// LIGHTBOX's video lanes: the sequence (lane 0, V1) and the stacked lanes above it, always
    /// this many in all, empty or not.
    public static let videoLanes = 10
    /// The stacked lanes above the sequence.
    public static let maxVideoLayers = videoLanes - 1

    public func layerClip(id: UUID) -> LayerClip? {
        for layer in videoLayers { if let clip = layer.clips.first(where: { $0.id == id }) { return clip } }
        return nil
    }

    /// The stacked lane (0 is the one just above the sequence) and position of a stacked clip.
    public func layerLocation(id: UUID) -> (layer: Int, index: Int)? {
        for (l, layer) in videoLayers.enumerated() {
            if let i = layer.clips.firstIndex(where: { $0.id == id }) { return (l, i) }
        }
        return nil
    }

    /// The video lane (0 for the sequence) a clip of the sequence or a stacked clip is on.
    public func videoLane(ofClip id: UUID) -> Int? {
        if index(ofClip: id) != nil { return 0 }
        return layerLocation(id: id).map { $0.layer + 1 }
    }

    /// Whether a clip of `range` could go on stacked lane `layer`, clear of its clips but `excluding`.
    public func layerFits(_ range: MediaTimeRange, onLayer layer: Int, excluding: UUID? = nil) -> Bool {
        guard layer >= 0, layer < Self.maxVideoLayers else { return false }
        return layer >= videoLayers.count || videoLayers[layer].fits(range, excluding: excluding)
    }

    /// Whether `range` is clear of the sequence's clips but `excluding`: in a gap, or after the end.
    public func sequenceFits(_ range: MediaTimeRange, excluding: UUID? = nil) -> Bool {
        SequenceMap(project: self).entries.allSatisfy { entry in
            entry.clipID == excluding || entry.compositionRange.end <= range.start
                || entry.compositionRange.start >= range.end
        }
    }

    /// Whether `range` is clear on video lane `lane` (0 for the sequence).
    public func videoLaneFits(_ range: MediaTimeRange, lane: Int, excluding: UUID? = nil) -> Bool {
        lane == 0
            ? sequenceFits(range, excluding: excluding) : layerFits(range, onLayer: lane - 1, excluding: excluding)
    }

    /// Stacked lane `layer` exists to put a clip on (lanes are numbered by place, so the ones
    /// under it are made too, empty).
    mutating func ensureVideoLayer(_ layer: Int) {
        while videoLayers.count <= layer { videoLayers.append(VideoLayer()) }
    }

    /// Empty lanes at the top aren't kept; every lane always shows, so nothing moves.
    mutating func pruneVideoLayers() {
        while videoLayers.last?.clips.isEmpty == true { videoLayers.removeLast() }
    }

    /// The sequence remade from clips at absolute times, each clip's gap the space before it.
    mutating func setSequence(_ items: [(clip: TimelineClip, start: MediaTime)]) {
        var cursor = MediaTime.zero
        clips = items.sorted { $0.start < $1.start }.map { item in
            var clip = item.clip
            clip.gap = max(item.start - cursor, .zero)
            cursor = max(item.start, cursor) + clip.compositionDuration
            return clip
        }
    }
}

/// New clips from `sources`, one after another from `start` (the playhead): on the lowest video
/// lane where the whole run is clear, the sequence first, so nothing is covered or pushed.
/// Refused when no lane has room.
public struct AddClipsAtCommand: EditingCommand {
    public let sources: [SourceAsset]
    public let start: MediaTime
    public let clipIDs: [UUID]

    public init(sources: [SourceAsset], start: MediaTime) {
        self.sources = sources
        self.start = max(start, .zero)
        self.clipIDs = sources.map { _ in UUID() }
    }

    public var actionName: String { sources.count == 1 ? "Add Clip" : "Add Clips" }

    /// The lane they went on, once applied to a project (0 for the sequence).
    public func lane(in project: Project) -> Int? { clipIDs.first.flatMap { project.videoLane(ofClip: $0) } }

    public func apply(to project: inout Project) throws {
        guard !sources.isEmpty else { return }
        var at = start
        var run: [(clip: TimelineClip, start: MediaTime)] = []
        for (source, id) in zip(sources, clipIDs) {
            let clip = TimelineClip(id: id, sourceID: source.id, sourceRange: source.defaultClipRange)
            run.append((clip, at))
            at = at + clip.compositionDuration
        }
        let whole = MediaTimeRange(start: start, end: at)
        guard let lane = (0..<Project.videoLanes).first(where: { project.videoLaneFits(whole, lane: $0) }) else {
            throw EditError.noRoom
        }
        for source in sources where project.source(id: source.id) == nil { project.sources.append(source) }
        if lane == 0 {
            project.setSequence(SequencePlacement(project: project).items + run)
        } else {
            project.ensureVideoLayer(lane - 1)
            for item in run { project.videoLayers[lane - 1].insert(LayerClip(clip: item.clip, start: item.start)) }
        }
    }
}

/// Moves a clip of the sequence or a stacked clip to `start` on video lane `lane` (0 for the
/// sequence), every other clip staying where it is. Refused where it would overlap a clip there,
/// and for a clip of the sequence played at another speed going up (stacked clips play at
/// normal speed). Moves along the sequence itself are `PlaceClipCommand`'s.
public struct MoveVideoClipCommand: EditingCommand {
    public let clipID: UUID
    public let lane: Int
    public let start: MediaTime

    public init(clipID: UUID, lane: Int, start: MediaTime) {
        self.clipID = clipID
        self.lane = lane
        self.start = max(start, .zero)
    }

    public var actionName: String { "Move Clip" }

    /// Whether the move can be made in `project`.
    public static func canMove(_ clipID: UUID, toLane lane: Int, start: MediaTime, in project: Project) -> Bool {
        guard lane >= 0, lane < Project.videoLanes else { return false }
        let clip: TimelineClip
        if let i = project.index(ofClip: clipID) {
            clip = project.clips[i]
            if lane > 0, clip.speed != 1 { return false }
        } else if let layered = project.layerClip(id: clipID) {
            clip = layered.clip
        } else {
            return false
        }
        let range = MediaTimeRange(start: max(start, .zero), duration: clip.compositionDuration)
        return project.videoLaneFits(range, lane: lane, excluding: clipID)
    }

    public func apply(to project: inout Project) throws {
        guard Self.canMove(clipID, toLane: lane, start: start, in: project) else {
            throw project.videoLane(ofClip: clipID) == nil ? EditError.clipNotFound : EditError.noRoom
        }
        // Lifted off wherever it is, the others staying put.
        let clip: TimelineClip
        if let i = project.index(ofClip: clipID) {
            clip = project.clips[i]
            project.setSequence(SequencePlacement(project: project).items.filter { $0.clip.id != clipID })
        } else {
            let at = project.layerLocation(id: clipID)!
            clip = project.videoLayers[at.layer].clips.remove(at: at.index).clip
        }
        if lane == 0 {
            project.setSequence(SequencePlacement(project: project).items + [(clip, start)])
        } else {
            project.ensureVideoLayer(lane - 1)
            project.videoLayers[lane - 1].insert(LayerClip(clip: clip, start: start))
        }
        project.pruneVideoLayers()
    }
}

/// Cuts a stacked clip in two at a composition time; the second half gets `newClipID`.
public struct SplitLayerClipCommand: EditingCommand {
    public let clipID: UUID
    public let time: MediaTime
    public let newClipID: UUID

    public init(clipID: UUID, time: MediaTime, newClipID: UUID = UUID()) {
        self.clipID = clipID
        self.time = time
        self.newClipID = newClipID
    }

    public var actionName: String { "Split Stacked Clip" }

    /// Whether a cut at `time` leaves two halves long enough to keep.
    public static func canSplit(_ clip: LayerClip, at time: MediaTime) -> Bool {
        time - clip.start >= minimumClipDuration && clip.timelineRange.end - time >= minimumClipDuration
    }

    public func apply(to project: inout Project) throws {
        guard let at = project.layerLocation(id: clipID) else { throw EditError.clipNotFound }
        let clip = project.videoLayers[at.layer].clips[at.index]
        guard Self.canSplit(clip, at: time) else { throw EditError.invalidRange }
        let cut = clip.clip.sourceRange.start + (time - clip.start)
        var first = clip
        first.clip.sourceRange = MediaTimeRange(start: clip.clip.sourceRange.start, end: cut)
        var second = clip
        second.clip.id = newClipID
        second.start = time
        second.clip.sourceRange = MediaTimeRange(start: cut, end: clip.clip.sourceRange.end)
        project.videoLayers[at.layer].clips[at.index] = first
        project.videoLayers[at.layer].clips.insert(second, at: at.index + 1)
    }
}

/// Takes a stacked clip off its lane (its source stays in the project).
public struct RemoveLayerClipCommand: EditingCommand {
    public let clipID: UUID
    public init(clipID: UUID) { self.clipID = clipID }
    public var actionName: String { "Remove Stacked Clip" }

    public func apply(to project: inout Project) throws {
        guard let at = project.layerLocation(id: clipID) else { throw EditError.clipNotFound }
        project.videoLayers[at.layer].clips.remove(at: at.index)
        project.pruneVideoLayers()
    }
}
