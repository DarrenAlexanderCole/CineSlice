import Foundation

// MARK: - The bin

/// A sound kept in the bin: a file in the project's Media folder, not yet (or not only) on a
/// sound lane. Putting it on a lane makes a `SoundClip` of the file.
public struct BinSound: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var originalFilename: String?
    public var duration: MediaTime
    public var importedAt: Date
    /// Recorded on the Record page: the bin keeps it in its TAKES folder.
    public var isTake: Bool

    public init(
        id: UUID = UUID(), fileName: String, originalFilename: String? = nil, duration: MediaTime,
        importedAt: Date = Date(), isTake: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFilename = originalFilename
        self.duration = duration
        self.importedAt = importedAt
        self.isTake = isTake
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, originalFilename, duration, importedAt, isTake
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        duration = try c.decode(MediaTime.self, forKey: .duration)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        isTake = try c.decodeIfPresent(Bool.self, forKey: .isTake) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encodeIfPresent(originalFilename, forKey: .originalFilename)
        try c.encode(duration, forKey: .duration)
        try c.encode(importedAt, forKey: .importedAt)
        if isTake { try c.encode(isTake, forKey: .isTake) }
    }
}

extension Project {
    public func binSound(id: UUID) -> BinSound? { binSounds.first { $0.id == id } }

    /// How many places use a source (the sequence and the stacked lanes) or a bin sound's file
    /// (the sound lanes).
    public func binUses(of id: UUID) -> Int {
        if let sound = binSound(id: id) {
            return soundTracks.reduce(0) { $0 + $1.clips.filter { $0.fileName == sound.fileName }.count }
        }
        return clips.filter { $0.sourceID == id }.count
            + videoLayers.reduce(0) { $0 + $1.clips.filter { $0.clip.sourceID == id }.count }
    }
}

/// Puts media in the project's bin without adding it to the timeline: pictures as sources,
/// sounds as bin sounds. From the bin, `AddClipsCommand` adds pictures to the sequence and
/// `AddSoundCommand` sounds to a lane.
public struct AddToBinCommand: EditingCommand {
    public let sources: [SourceAsset]
    public let sounds: [BinSound]

    public init(sources: [SourceAsset] = [], sounds: [BinSound] = []) {
        self.sources = sources
        self.sounds = sounds
    }

    public var actionName: String {
        let count = sources.count + sounds.count
        let takes = sources.allSatisfy(\.isTake) && sounds.allSatisfy(\.isTake)
        return takes ? (count == 1 ? "Add Take" : "Add Takes") : "Add to Bin"
    }

    public func apply(to project: inout Project) throws {
        for source in sources where project.source(id: source.id) == nil {
            project.sources.append(source)
        }
        for sound in sounds where project.binSound(id: sound.id) == nil {
            project.binSounds.append(sound)
        }
    }
}

/// Takes media out of the bin, and off the timeline wherever it's used: the clips of a source
/// leave the sequence (the ones after close up) and the stacked lanes; a bin sound's file
/// leaves the sound lanes. The files stay on disk, so undo brings everything back.
public struct RemoveFromBinCommand: EditingCommand {
    public let ids: Set<UUID>

    public init(ids: Set<UUID>) {
        self.ids = ids
    }

    public var actionName: String { "Remove from Bin" }

    public func apply(to project: inout Project) throws {
        let files = Set(project.binSounds.filter { ids.contains($0.id) }.map(\.fileName))
        guard project.sources.contains(where: { ids.contains($0.id) }) || !files.isEmpty else {
            throw EditError.clipNotFound
        }
        project.sources.removeAll { ids.contains($0.id) }
        project.clips.removeAll { ids.contains($0.sourceID) }
        for i in project.videoLayers.indices {
            project.videoLayers[i].clips.removeAll { ids.contains($0.clip.sourceID) }
        }
        project.pruneVideoLayers()
        project.binSounds.removeAll { ids.contains($0.id) }
        for i in project.soundTracks.indices {
            project.soundTracks[i].clips.removeAll { files.contains($0.fileName) }
        }
        project.pruneSoundTracks()
    }
}

/// Renames a piece of media in the bin. A picture's clips show the new name too. An empty name
/// is refused.
public struct RenameMediaCommand: EditingCommand {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var actionName: String { "Rename" }

    public func apply(to project: inout Project) throws {
        guard !name.isEmpty else { throw EditError.invalidRange }
        if let i = project.sources.firstIndex(where: { $0.id == id }) {
            project.sources[i].originalFilename = name
        } else if let i = project.binSounds.firstIndex(where: { $0.id == id }) {
            let file = project.binSounds[i].fileName
            project.binSounds[i].originalFilename = name
            // Its sounds on the lanes carry the name too.
            for t in project.soundTracks.indices {
                for c in project.soundTracks[t].clips.indices where project.soundTracks[t].clips[c].fileName == file {
                    project.soundTracks[t].clips[c].originalFilename = name
                }
            }
        } else {
            throw EditError.clipNotFound
        }
    }
}
