import Foundation

// MARK: - Source media

/// An imported media file. Originals are never modified; the file lives in the
/// project's Media folder and is referenced by a *relative* file name so the
/// project survives app container path changes.
public struct SourceAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var originalFilename: String?
    public var duration: MediaTime
    /// Display size after applying the track's preferred transform.
    public var width: Int
    public var height: Int
    public var nominalFrameRate: Double
    public var hasAudio: Bool
    public var importedAt: Date

    public init(
        id: UUID = UUID(), fileName: String, originalFilename: String? = nil,
        duration: MediaTime, width: Int, height: Int,
        nominalFrameRate: Double = 30, hasAudio: Bool = false, importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFilename = originalFilename
        self.duration = duration
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.hasAudio = hasAudio
        self.importedAt = importedAt
    }

    public var frameRate: Double { nominalFrameRate > 0 ? nominalFrameRate : 30 }

    /// One frame at the source's nominal rate.
    public var frameDuration: MediaTime {
        MediaTime(value: 1, timescale: Int32(max(1, frameRate.rounded())))
    }

    public var orientationLabel: String {
        if width == height { return "Square" }
        return width > height ? "Landscape" : "Portrait"
    }
}

// MARK: - Timeline

public enum Framing: String, Codable, Sendable, CaseIterable {
    /// Fill the 9:16 frame, cropping the overflow (default).
    case fill
    /// Fit the whole source inside the frame with letterboxing.
    case fit
}

/// One moment of a source placed in the sequence. Clips are placed
/// back-to-back in array order (no gaps in Phase 1).
public struct TimelineClip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    /// The used portion of the source, in source time.
    public var sourceRange: MediaTimeRange
    /// Playback speed. 1 = normal. Stored now; exposed in a later phase.
    public var speed: Double
    public var framing: Framing

    public init(
        id: UUID = UUID(), sourceID: UUID, sourceRange: MediaTimeRange,
        speed: Double = 1, framing: Framing = .fill
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.speed = speed
        self.framing = framing
    }

    /// Length of this clip on the composition timeline.
    public var compositionDuration: MediaTime {
        speed == 1 ? sourceRange.duration : sourceRange.duration.scaled(by: 1 / speed)
    }
}

// MARK: - Audio, automation, loop

/// The user-supplied reference music. Stored in the project's Media folder like
/// clip media; when taken from a video, only its sound is kept (as .m4a).
public struct AudioTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var originalFilename: String?
    public var duration: MediaTime
    /// Where audio time 0 sits on the composition timeline (may be negative).
    public var offset: MediaTime
    public var volume: Float

    public init(
        id: UUID = UUID(), fileName: String, originalFilename: String? = nil,
        duration: MediaTime, offset: MediaTime = .zero, volume: Float = 1
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFilename = originalFilename
        self.duration = duration
        self.offset = offset
        self.volume = volume
    }
}

public struct AutomationPoint: Codable, Hashable, Sendable {
    public var time: MediaTime
    public var value: Float
    public init(time: MediaTime, value: Float) {
        self.time = time
        self.value = value
    }
}

public struct LoopRange: Codable, Hashable, Sendable {
    public var range: MediaTimeRange
    public var isEnabled: Bool
    public init(range: MediaTimeRange, isEnabled: Bool = true) {
        self.range = range
        self.isEnabled = isEnabled
    }
}

// MARK: - Export

/// What the exported file contains. Preview always plays the full mix.
public enum SoundPolicy: String, Codable, CaseIterable, Sendable {
    /// No sound: for attaching the licensed song inside Instagram afterwards.
    case silent
    /// The clips' own sound; the reference music is left out.
    case clipsOnly
    /// Exactly what the preview plays. For private drafts, not for Instagram upload.
    case clipsAndMusic

    public var includesClipAudio: Bool { self != .silent }
    public var includesMusic: Bool { self == .clipsAndMusic }
}

public struct ExportSettings: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    /// nil until the user picks one; see `Project.exportSoundPolicy` for the default.
    public var soundPolicy: SoundPolicy?

    public init(width: Int = 1080, height: Int = 1920, frameRate: Int = 30, soundPolicy: SoundPolicy? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.soundPolicy = soundPolicy
    }

    enum CodingKeys: String, CodingKey {
        case width, height, frameRate, soundPolicy
        /// Phase 1: false meant a silent export.
        case includeClipAudio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        frameRate = try c.decode(Int.self, forKey: .frameRate)
        if let policy = try c.decodeIfPresent(SoundPolicy.self, forKey: .soundPolicy) {
            soundPolicy = policy
        } else {
            // Clip audio on was the Phase 1 default, so only "off" counts as a choice.
            let clipAudio = try c.decodeIfPresent(Bool.self, forKey: .includeClipAudio) ?? true
            soundPolicy = clipAudio ? nil : .silent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encodeIfPresent(soundPolicy, forKey: .soundPolicy)
    }

    public static let vertical1080 = ExportSettings()

    public var aspectLabel: String { width * 16 == height * 9 ? "9:16" : "\(width):\(height)" }
}

// MARK: - Project

public enum ProjectError: Error, Equatable {
    case unsupportedSchema(Int)
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var sources: [SourceAsset]
    public var clips: [TimelineClip]
    public var clipAudioVolume: Float
    public var referenceAudio: AudioTrack?
    public var volumeAutomation: [AutomationPoint]
    public var loop: LoopRange?
    public var exportSettings: ExportSettings

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.schemaVersion = Project.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.sources = []
        self.clips = []
        self.clipAudioVolume = 1
        self.referenceAudio = nil
        self.volumeAutomation = []
        self.loop = nil
        self.exportSettings = .vertical1080
    }

    // Tolerant decoding: new optional fields can be added without breaking old files.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, modifiedAt, sources, clips
        case clipAudioVolume, referenceAudio, volumeAutomation, loop, exportSettings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Project.currentSchemaVersion else { throw ProjectError.unsupportedSchema(version) }
        schemaVersion = Project.currentSchemaVersion
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        sources = try c.decodeIfPresent([SourceAsset].self, forKey: .sources) ?? []
        clips = try c.decodeIfPresent([TimelineClip].self, forKey: .clips) ?? []
        clipAudioVolume = try c.decodeIfPresent(Float.self, forKey: .clipAudioVolume) ?? 1
        referenceAudio = try c.decodeIfPresent(AudioTrack.self, forKey: .referenceAudio)
        volumeAutomation = try c.decodeIfPresent([AutomationPoint].self, forKey: .volumeAutomation) ?? []
        loop = try c.decodeIfPresent(LoopRange.self, forKey: .loop)
        exportSettings = try c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? .vertical1080
    }

    public func source(id: UUID) -> SourceAsset? { sources.first { $0.id == id } }
    public func source(for clip: TimelineClip) -> SourceAsset? { source(id: clip.sourceID) }
    public func clip(id: UUID) -> TimelineClip? { clips.first { $0.id == id } }
    public func index(ofClip id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    public var duration: MediaTime {
        clips.reduce(MediaTime.zero) { $0 + $1.compositionDuration }
    }
}
