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

/// Adds sources (if not already present) and appends one full-length clip per source.
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
                    sourceRange: MediaTimeRange(start: .zero, duration: source.duration)))
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
