import Foundation

public enum EditError: Error, Equatable {
    case clipNotFound
    case sourceNotFound
    case invalidRange
    /// The music is locked in place.
    case locked
}

/// Every project mutation goes through a command so it can be undone.
public protocol EditingCommand {
    var actionName: String { get }
    func apply(to project: inout Project) throws
}

/// Minimum clip length on the source timeline (about two frames at 30 fps).
public let minimumClipDuration = MediaTime(value: 40, timescale: 600)

/// Adds sources (if not already present) and appends one clip per source: full length for
/// video, `SourceAsset.stillClipDuration` for a photo.
public struct AddClipsCommand: EditingCommand {
    public let sources: [SourceAsset]
    public let insertIndex: Int?
    public let clipIDs: [UUID]

    public init(sources: [SourceAsset], insertIndex: Int? = nil) {
        self.sources = sources
        self.insertIndex = insertIndex
        self.clipIDs = sources.map { _ in UUID() }
    }

    public var actionName: String { sources.count == 1 ? "Add Clip" : "Add Clips" }

    public func apply(to project: inout Project) throws {
        var newClips: [TimelineClip] = []
        for (source, clipID) in zip(sources, clipIDs) {
            if project.source(id: source.id) == nil { project.sources.append(source) }
            newClips.append(
                TimelineClip(
                    id: clipID, sourceID: source.id,
                    sourceRange: source.defaultClipRange))
        }
        let at = min(max(insertIndex ?? project.clips.count, 0), project.clips.count)
        project.clips.insert(contentsOf: newClips, at: at)
    }
}

public struct MoveClipCommand: EditingCommand {
    public let clipID: UUID
    public let toIndex: Int
    public init(clipID: UUID, toIndex: Int) {
        self.clipID = clipID
        self.toIndex = toIndex
    }
    public var actionName: String { "Move Clip" }
    public func apply(to project: inout Project) throws {
        guard let from = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        let clip = project.clips.remove(at: from)
        project.clips.insert(clip, at: min(max(toIndex, 0), project.clips.count))
    }
}

public struct RemoveClipCommand: EditingCommand {
    public let clipID: UUID
    public init(clipID: UUID) { self.clipID = clipID }
    public var actionName: String { "Remove Clip" }
    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        project.clips.remove(at: i)
        // The source stays in the project so undo (and re-adding) keeps working.
    }
}

public struct DuplicateClipCommand: EditingCommand {
    public let clipID: UUID
    public let newClipID: UUID
    public init(clipID: UUID, newClipID: UUID = UUID()) {
        self.clipID = clipID
        self.newClipID = newClipID
    }
    public var actionName: String { "Duplicate Clip" }
    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        var copy = project.clips[i]
        copy.id = newClipID
        project.clips.insert(copy, at: i + 1)
    }
}

/// Sets a clip's in/out on the source. The range is clamped to the source and
/// to `minimumClipDuration`; the original file is untouched.
public struct TrimClipCommand: EditingCommand {
    public let clipID: UUID
    public let sourceRange: MediaTimeRange
    public init(clipID: UUID, sourceRange: MediaTimeRange) {
        self.clipID = clipID
        self.sourceRange = sourceRange
    }
    public var actionName: String { "Trim Clip" }

    public static func clamp(_ range: MediaTimeRange, toSourceDuration total: MediaTime) -> MediaTimeRange {
        let minDur = min(minimumClipDuration, total)
        var start = range.start.clamped(to: .zero, total - minDur)
        var end = range.end.clamped(to: start + minDur, total)
        if end - start < minDur {
            start = max(.zero, end - minDur)
            end = start + minDur
        }
        return MediaTimeRange(start: start, end: end)
    }

    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        guard let source = project.source(for: project.clips[i]) else { throw EditError.sourceNotFound }
        guard sourceRange.duration > .zero else { throw EditError.invalidRange }
        project.clips[i].sourceRange = TrimClipCommand.clamp(sourceRange, toSourceDuration: source.duration)
    }
}

public struct SetFramingCommand: EditingCommand {
    public let clipID: UUID
    public let framing: Framing
    public init(clipID: UUID, framing: Framing) {
        self.clipID = clipID
        self.framing = framing
    }
    public var actionName: String { "Change Framing" }
    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        project.clips[i].framing = framing
    }
}

/// Sets a clip's push-in; a full-frame crop (or nil) takes it off.
public struct SetCropCommand: EditingCommand {
    public let clipID: UUID
    public let crop: Crop?
    public init(clipID: UUID, crop: Crop?) {
        self.clipID = clipID
        self.crop = crop.flatMap { $0.isFull ? nil : $0 }
    }
    public var actionName: String { crop == nil ? "Reset Crop" : "Crop Clip" }
    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        project.clips[i].crop = crop
    }
}

/// Plays a clip's sound processed (voice only, or voices reduced), or with nil as recorded.
public struct SetVoiceTreatmentCommand: EditingCommand {
    public let clipID: UUID
    public let treatment: VoiceTreatment?
    public init(clipID: UUID, treatment: VoiceTreatment?) {
        self.clipID = clipID
        self.treatment = treatment
    }
    public var actionName: String {
        switch treatment {
        case nil: return "Original Sound"
        case .voiceOnly: return "Voice Only"
        case .reduceVoice: return "Reduce Voice"
        }
    }
    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        project.clips[i].voice = treatment
    }
}

public struct RenameProjectCommand: EditingCommand {
    public let name: String
    public init(name: String) { self.name = name }
    public var actionName: String { "Rename Project" }
    public func apply(to project: inout Project) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.name = trimmed.isEmpty ? project.name : trimmed
    }
}

public struct SetExportSettingsCommand: EditingCommand {
    public let settings: ExportSettings
    public init(settings: ExportSettings) { self.settings = settings }
    public var actionName: String { "Export Settings" }
    public func apply(to project: inout Project) throws { project.exportSettings = settings }
}

// MARK: - Music and levels

/// Adds, replaces or (with nil) removes the reference music.
public struct SetReferenceAudioCommand: EditingCommand {
    public let track: AudioTrack?
    public init(track: AudioTrack?) { self.track = track }
    public var actionName: String {
        switch track?.kind {
        case nil: return "Remove Music"
        case .myMusic: return "Set Music"
        case .quickClick: return "Set Quick Click"
        case .billboards: return "Set Billboards Guide"
        }
    }
    public func apply(to project: inout Project) throws { project.referenceAudio = track }
}

public struct SetMusicOffsetCommand: EditingCommand {
    public let offset: MediaTime
    public init(offset: MediaTime) { self.offset = offset }
    public var actionName: String { "Move Music" }
    public func apply(to project: inout Project) throws {
        guard var track = project.referenceAudio else { throw EditError.sourceNotFound }
        guard !track.isLocked else { throw EditError.locked }
        track.offset = track.clampedOffset(offset, sequenceDuration: project.duration)
        project.referenceAudio = track
    }
}

/// Turns the picture to 16:9 (or back to 9:16). Clips keep their framing, refitted to the new shape.
public struct SetOrientationCommand: EditingCommand {
    public let landscape: Bool
    public init(landscape: Bool) { self.landscape = landscape }
    public var actionName: String { landscape ? "Horizontal 16:9" : "Vertical 9:16" }
    public func apply(to project: inout Project) throws {
        project.exportSettings = project.exportSettings.oriented(landscape: landscape)
    }
}

/// Locks the music in place (or unlocks it) so it can't be slid or nudged by accident.
public struct SetMusicLockCommand: EditingCommand {
    public let isLocked: Bool
    public init(isLocked: Bool) { self.isLocked = isLocked }
    public var actionName: String { isLocked ? "Lock Music" : "Unlock Music" }
    public func apply(to project: inout Project) throws {
        guard project.referenceAudio != nil else { throw EditError.sourceNotFound }
        project.referenceAudio?.isLocked = isLocked
    }
}

public struct SetClipVolumeCommand: EditingCommand {
    public let clipID: UUID
    public let volume: Float
    public init(clipID: UUID, volume: Float) {
        self.clipID = clipID
        self.volume = volume
    }
    public var actionName: String { "Clip Level" }
    public func apply(to project: inout Project) throws {
        guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
        project.clips[i].volume = min(max(volume, 0), 1)
    }
}

public struct SetMusicVolumeCommand: EditingCommand {
    public let volume: Float
    public init(volume: Float) { self.volume = volume }
    public var actionName: String { "Music Level" }
    public func apply(to project: inout Project) throws {
        guard project.referenceAudio != nil else { throw EditError.sourceNotFound }
        project.referenceAudio?.volume = min(max(volume, 0), 1)
    }
}

/// Sets (or clears) the loop region in composition time, fitted to the sequence.
public struct SetLoopCommand: EditingCommand {
    public let loop: LoopRange?
    public init(loop: LoopRange?) { self.loop = loop }
    public var actionName: String { "Loop Region" }
    public func apply(to project: inout Project) throws {
        project.loop = loop?.clamped(toSequence: project.duration)
    }
}

/// Records one fader pass, or one stroke drawn by finger, into a curve, replacing whatever it
/// overlaps (one undo step). A drawn stroke is smoothed more, since a finger wobbles.
public struct WriteAutomationCommand: EditingCommand {
    public let target: AutomationTarget
    public let samples: [AutomationPoint]
    public let drawn: Bool
    public init(target: AutomationTarget, samples: [AutomationPoint], drawn: Bool = false) {
        self.target = target
        self.samples = samples
        self.drawn = drawn
    }
    public var actionName: String {
        switch (target, drawn) {
        case (.music, false): "Record Music Level"
        case (.clipAudio, false): "Record Clip Level"
        case (.music, true): "Draw Music Curve"
        case (.clipAudio, true): "Draw Clip Curve"
        }
    }
    public func apply(to project: inout Project) throws {
        if target == .music, project.referenceAudio == nil { throw EditError.sourceNotFound }
        let tolerance = drawn ? AutomationLane.drawnTolerance : AutomationLane.tolerance
        guard
            let pass = AutomationSegment(
                recorded: drawn ? smoothed(samples) : samples, sequenceDuration: project.duration,
                tolerance: tolerance)
        else {
            throw EditError.invalidRange
        }
        switch target {
        case .music: project.automation.music.write(pass)
        case .clipAudio: project.writeClipLevel(pass)
        }
    }
}

/// Moves one recorded pass up or down as a whole (a static fader move inside it). `time` is in
/// the curve's own time: composition time for the music, the clip's source time for a clip.
public struct TrimAutomationCommand: EditingCommand {
    public let target: AutomationTarget
    public let clipID: UUID?
    public let time: MediaTime
    public let delta: Float
    public init(target: AutomationTarget, clipID: UUID? = nil, time: MediaTime, delta: Float) {
        self.target = target
        self.clipID = clipID
        self.time = time
        self.delta = delta
    }
    public var actionName: String { target == .music ? "Trim Music Curve" : "Trim Clip Curve" }
    public func apply(to project: inout Project) throws {
        let shifted: Bool
        switch target {
        case .music:
            shifted = project.automation.music.shiftPass(containing: time, by: delta)
        case .clipAudio:
            guard let clipID, let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
            shifted = project.clips[i].levelCurve.shiftPass(containing: time, by: delta)
        }
        guard shifted else { throw EditError.invalidRange }
    }
}

/// Edits one point of a curve by hand. Points are named by pass and index in the curve's own
/// time (composition time for the music, the clip's source time for a clip, which bounds it).
public struct EditCurvePointCommand: EditingCommand {
    public enum Edit: Hashable, Sendable {
        case move(segment: Int, point: Int, to: AutomationPoint)
        case add(AutomationPoint)
        case remove(segment: Int, point: Int)
    }

    public let target: AutomationTarget
    public let clipID: UUID?
    public let edit: Edit
    public init(target: AutomationTarget, clipID: UUID? = nil, edit: Edit) {
        self.target = target
        self.clipID = clipID
        self.edit = edit
    }
    public var actionName: String {
        switch edit {
        case .move: "Move Curve Point"
        case .add: "Add Curve Point"
        case .remove: "Delete Curve Point"
        }
    }
    public func apply(to project: inout Project) throws {
        let done: Bool
        switch target {
        case .music:
            guard project.referenceAudio != nil else { throw EditError.sourceNotFound }
            done = Self.apply(
                edit, to: &project.automation.music, within: MediaTimeRange(start: .zero, end: project.duration))
        case .clipAudio:
            guard let clipID, let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
            done = Self.apply(edit, to: &project.clips[i].levelCurve, within: project.clips[i].sourceRange)
        }
        guard done else { throw EditError.invalidRange }
    }

    private static func apply(_ edit: Edit, to lane: inout AutomationLane, within bounds: MediaTimeRange) -> Bool {
        switch edit {
        case .move(let s, let p, let point): lane.movePoint(segment: s, point: p, to: point, within: bounds)
        case .add(let point): lane.addPoint(point, within: bounds)
        case .remove(let s, let p): lane.removePoint(segment: s, point: p)
        }
    }
}

/// Clears the music curve, or one clip's curve (every clip's when `clipID` is nil).
public struct ClearAutomationCommand: EditingCommand {
    public let target: AutomationTarget
    public let clipID: UUID?
    public init(target: AutomationTarget, clipID: UUID? = nil) {
        self.target = target
        self.clipID = clipID
    }
    public var actionName: String {
        switch target {
        case .music: "Clear Music Curve"
        case .clipAudio: clipID == nil ? "Clear Clip Curves" : "Clear Clip Curve"
        }
    }
    public func apply(to project: inout Project) throws {
        switch target {
        case .music:
            project.automation.music = AutomationLane()
        case .clipAudio:
            if let clipID {
                guard let i = project.index(ofClip: clipID) else { throw EditError.clipNotFound }
                project.clips[i].levelCurve = AutomationLane()
            } else {
                for i in project.clips.indices { project.clips[i].levelCurve = AutomationLane() }
            }
        }
    }
}
