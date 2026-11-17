import Foundation

public enum EditError: Error, Equatable {
    case clipNotFound
    case sourceNotFound
    case invalidRange
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
    public var actionName: String { track == nil ? "Remove Music" : "Set Music" }
    public func apply(to project: inout Project) throws { project.referenceAudio = track }
}

public struct SetMusicOffsetCommand: EditingCommand {
    public let offset: MediaTime
    public init(offset: MediaTime) { self.offset = offset }
    public var actionName: String { "Move Music" }
    public func apply(to project: inout Project) throws {
        guard var track = project.referenceAudio else { throw EditError.sourceNotFound }
        track.offset = track.clampedOffset(offset, sequenceDuration: project.duration)
        project.referenceAudio = track
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

/// Records one fader pass into a curve, replacing whatever it overlaps (one undo step).
public struct WriteAutomationCommand: EditingCommand {
    public let target: AutomationTarget
    public let samples: [AutomationPoint]
    public init(target: AutomationTarget, samples: [AutomationPoint]) {
        self.target = target
        self.samples = samples
    }
    public var actionName: String { target == .music ? "Record Music Level" : "Record Clip Level" }
    public func apply(to project: inout Project) throws {
        if target == .music, project.referenceAudio == nil { throw EditError.sourceNotFound }
        guard let pass = AutomationSegment(recorded: samples, sequenceDuration: project.duration) else {
            throw EditError.invalidRange
        }
        switch target {
        case .music: project.automation.music.write(pass)
        case .clipAudio: project.writeClipLevel(pass)
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
