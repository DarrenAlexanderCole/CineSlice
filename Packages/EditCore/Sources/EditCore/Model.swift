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
    /// A photo, stored as a silent movie that holds the picture for `duration`.
    public var isStill: Bool
    public var importedAt: Date

    public init(
        id: UUID = UUID(), fileName: String, originalFilename: String? = nil,
        duration: MediaTime, width: Int, height: Int,
        nominalFrameRate: Double = 30, hasAudio: Bool = false, isStill: Bool = false, importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFilename = originalFilename
        self.duration = duration
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.hasAudio = hasAudio
        self.isStill = isStill
        self.importedAt = importedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, originalFilename, duration, width, height, nominalFrameRate, hasAudio, isStill
        case importedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        duration = try c.decode(MediaTime.self, forKey: .duration)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        nominalFrameRate = try c.decode(Double.self, forKey: .nominalFrameRate)
        hasAudio = try c.decode(Bool.self, forKey: .hasAudio)
        isStill = try c.decodeIfPresent(Bool.self, forKey: .isStill) ?? false
        importedAt = try c.decode(Date.self, forKey: .importedAt)
    }

    /// How long a photo plays when first added; its source runs longer, so it can be stretched.
    public static let stillClipDuration = MediaTime(seconds: 3)

    /// The part used when the source is first added: all of a video, the opening seconds of a photo.
    public var defaultClipRange: MediaTimeRange {
        MediaTimeRange(start: .zero, duration: isStill ? min(duration, Self.stillClipDuration) : duration)
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

/// A push-in on a clip: the part of the framed picture that fills the frame, as fractions of the
/// frame. It keeps the frame's shape, so `size` is both its width and its height share.
public struct Crop: Codable, Hashable, Sendable {
    /// Left and top edges, 0…1 - size.
    public var x: Double
    public var y: Double
    /// 1 shows the whole frame; ½ is a 2× push-in.
    public var size: Double

    /// The tightest push-in, 4×.
    public static let minSize = 0.25
    public static let full = Crop(x: 0, y: 0, size: 1)

    /// Clamped to stay inside the frame.
    public init(x: Double, y: Double, size: Double) {
        let s = min(max(size, Self.minSize), 1)
        self.size = s
        self.x = min(max(x, 0), 1 - s)
        self.y = min(max(y, 0), 1 - s)
    }

    /// The same size around a new centre (fractions of the frame), kept inside it.
    public func centred(at cx: Double, _ cy: Double) -> Crop {
        Crop(x: cx - size / 2, y: cy - size / 2, size: size)
    }

    /// A new size about the same centre.
    public func sized(_ newSize: Double) -> Crop {
        let s = min(max(newSize, Self.minSize), 1)
        return Crop(x: x + (size - s) / 2, y: y + (size - s) / 2, size: s)
    }

    public var isFull: Bool { size >= 0.999 }
    /// How much it pushes in: 1 / size.
    public var magnification: Double { 1 / size }
}

/// A clip's own sound split on the device by source separation, played back as two levels: the
/// voices, and everything else (the scene, music, noise). The source file is never changed; the
/// split sound is derived data in the project's Cache.
public struct SoundBalance: Codable, Hashable, Sendable {
    /// The voices' level, 0…1.
    public var voice: Float
    /// Everything but the voices, 0…1.
    public var scene: Float
    public init(voice: Float, scene: Float) {
        self.voice = voice
        self.scene = scene
    }
    /// Where a clip starts when its sound is first split: the voices taken out, the scene kept.
    public static let removeVoice = SoundBalance(voice: 0, scene: 1)
    public static let voiceOnly = SoundBalance(voice: 1, scene: 0)
}

/// The two halves of a split sound, each kept as its own file.
public enum SoundStem: String, Codable, Sendable, CaseIterable {
    /// The voices. (Raw values are the names of the cache files made before the levels existed.)
    case voice = "voiceOnly"
    /// Everything but the voices.
    case scene = "reduceVoice"
}

/// One moment of a source placed in the sequence. Clips play in array order, each after its
/// `gap` (black and silence) following the one before; with no gaps they're back to back.
public struct TimelineClip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    /// The used portion of the source, in source time.
    public var sourceRange: MediaTimeRange
    /// Playback speed. 1 = normal. Stored now; exposed in a later phase.
    public var speed: Double
    public var framing: Framing
    /// A push-in on the framed picture; nil shows the whole frame.
    public var crop: Crop?
    /// This clip's own sound level, 0…1.
    public var volume: Float
    /// Recorded level passes in source time, so the curve travels with the clip. Parts outside
    /// `sourceRange` are kept (a trim can bring them back) but don't play.
    public var levelCurve: AutomationLane
    /// Plays the sound split into voices and scene at these levels; nil plays it as recorded.
    public var balance: SoundBalance?
    /// Black and silence before it, after the clip before (or the sequence's start). Zero keeps
    /// it against that clip, as every clip was before LIGHTBOX could leave gaps.
    public var gap: MediaTime = .zero

    public init(
        id: UUID = UUID(), sourceID: UUID, sourceRange: MediaTimeRange,
        speed: Double = 1, framing: Framing = .fill, crop: Crop? = nil, volume: Float = 1,
        levelCurve: AutomationLane = .init(), balance: SoundBalance? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.speed = speed
        self.framing = framing
        self.crop = crop
        self.volume = volume
        self.levelCurve = levelCurve
        self.balance = balance
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, sourceRange, speed, framing, crop, volume, levelCurve, balance, gap
        /// Before the levels: "voiceOnly" or "reduceVoice". Read, never written.
        case voice
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(sourceRange, forKey: .sourceRange)
        try c.encode(speed, forKey: .speed)
        try c.encode(framing, forKey: .framing)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encode(volume, forKey: .volume)
        try c.encode(levelCurve, forKey: .levelCurve)
        try c.encodeIfPresent(balance, forKey: .balance)
        if gap > .zero { try c.encode(gap, forKey: .gap) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourceRange = try c.decode(MediaTimeRange.self, forKey: .sourceRange)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        framing = try c.decodeIfPresent(Framing.self, forKey: .framing) ?? .fill
        crop = try c.decodeIfPresent(Crop.self, forKey: .crop)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        levelCurve = try c.decodeIfPresent(AutomationLane.self, forKey: .levelCurve) ?? AutomationLane()
        gap = try c.decodeIfPresent(MediaTime.self, forKey: .gap) ?? .zero
        if let balance = try c.decodeIfPresent(SoundBalance.self, forKey: .balance) {
            self.balance = balance
        } else {
            switch try c.decodeIfPresent(String.self, forKey: .voice) {
            case "voiceOnly": balance = .voiceOnly
            case "reduceVoice": balance = .removeVoice
            default: balance = nil
            }
        }
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
    /// Locked once lined up, so the song can't be bumped: `offset` changes are refused.
    public var isLocked: Bool
    /// How the track was made (Quick Click or Billboards guides); nil for older projects, which
    /// all used My Music.
    public var reference: MusicReference?
    /// Which of LIGHTBOX's audio lanes it sits on (0 is the first); nil in projects from before
    /// it could move between them, read as 0.
    public var lane: Int?

    public init(
        id: UUID = UUID(), fileName: String, originalFilename: String? = nil,
        duration: MediaTime, offset: MediaTime = .zero, volume: Float = 1, isLocked: Bool = false,
        reference: MusicReference? = nil, lane: Int? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFilename = originalFilename
        self.duration = duration
        self.offset = offset
        self.volume = volume
        self.isLocked = isLocked
        self.reference = reference
        self.lane = lane
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, originalFilename, duration, offset, volume, isLocked, reference, lane
    }

    /// The audio lane it sits on.
    public var audioLane: Int { lane ?? 0 }

    /// The whole song on the timeline, from where it starts (or 0, if it starts before the
    /// sequence) to its end, which may run past the sequence's.
    public var timelineRange: MediaTimeRange {
        MediaTimeRange(start: max(offset, .zero), end: max(offset + duration, .zero))
    }

    /// Where it came from; older tracks were all My Music.
    public var kind: MusicReference.Kind { reference?.kind ?? .myMusic }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        duration = try c.decode(MediaTime.self, forKey: .duration)
        offset = try c.decodeIfPresent(MediaTime.self, forKey: .offset) ?? .zero
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        reference = try c.decodeIfPresent(MusicReference.self, forKey: .reference)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane)
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

/// How the picture is compressed in the file.
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    /// Plays everywhere.
    case h264
    /// About a third smaller at the same quality; some older computers and apps can't play it.
    case hevc
}

public struct ExportSettings: Codable, Hashable, Sendable {
    /// The sequence's frame, in which clips are framed: 1080 on its short side. The file is
    /// this frame scaled to `resolution`.
    public var width: Int
    public var height: Int
    public var frameRate: Int
    /// nil until the user picks one; see `Project.exportSoundPolicy` for the default.
    public var soundPolicy: SoundPolicy?
    /// A vertical sequence exported for the feed: the centre 4:5 of the 9:16 frame (the part a
    /// feed shows), at the same width. Ignored for a horizontal sequence.
    public var cutsToFeed: Bool
    /// The file's short side in pixels (1080 is 1080p, 2160 is 4K); the frame keeps its shape.
    public var resolution: Int
    public var codec: VideoCodec
    /// Bits per second of picture; nil picks `autoVideoBitrate` for the resolution and frame rate.
    public var videoBitrate: Int?
    /// Bits per second of AAC sound.
    public var audioBitrate: Int
    /// Seconds between full frames: shorter scrubs better in other editors, longer is smaller.
    public var keyframeInterval: Double

    public static let resolutionRange = 480...2160
    public static let videoBitrateRange = 1_000_000...150_000_000
    public static let audioBitrateRange = 64_000...320_000
    public static let keyframeIntervalRange = 0.5...10.0
    public static let frameRates = [24, 25, 30, 48, 50, 60]

    public init(
        width: Int = 1080, height: Int = 1920, frameRate: Int = 30, soundPolicy: SoundPolicy? = nil,
        cutsToFeed: Bool = false, resolution: Int = 1080, codec: VideoCodec = .h264, videoBitrate: Int? = nil,
        audioBitrate: Int = 256_000, keyframeInterval: Double = 2
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.soundPolicy = soundPolicy
        self.cutsToFeed = cutsToFeed
        self.resolution = resolution
        self.codec = codec
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.keyframeInterval = keyframeInterval
    }

    enum CodingKeys: String, CodingKey {
        case width, height, frameRate, soundPolicy, cutsToFeed
        case resolution, codec, videoBitrate, audioBitrate, keyframeInterval
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
        cutsToFeed = try c.decodeIfPresent(Bool.self, forKey: .cutsToFeed) ?? false
        // Before these, every export was 1080p H.264 at an automatic bitrate.
        resolution = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? 1080
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? .h264
        videoBitrate = try c.decodeIfPresent(Int.self, forKey: .videoBitrate)
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? 256_000
        keyframeInterval = try c.decodeIfPresent(Double.self, forKey: .keyframeInterval) ?? 2
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encodeIfPresent(soundPolicy, forKey: .soundPolicy)
        if cutsToFeed { try c.encode(true, forKey: .cutsToFeed) }
        try c.encode(resolution, forKey: .resolution)
        try c.encode(codec, forKey: .codec)
        try c.encodeIfPresent(videoBitrate, forKey: .videoBitrate)
        try c.encode(audioBitrate, forKey: .audioBitrate)
        try c.encode(keyframeInterval, forKey: .keyframeInterval)
    }

    /// Whether the export is the feed's 4:5 cut of a vertical sequence.
    public var exportsFeedCut: Bool { cutsToFeed && !isLandscape }

    /// From the sequence frame to the file's pixels.
    private var scale: Double { Double(resolution) / Double(max(1, min(width, height))) }

    /// Encoders want even dimensions.
    private static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }

    /// The sequence frame at the file's resolution: what clips are framed in for export.
    public var frameWidth: Int { Self.even(Double(width) * scale) }
    public var frameHeight: Int { Self.even(Double(height) * scale) }

    /// The exported file's frame: the sequence frame, or its centre 4:5 for the feed.
    public var outputWidth: Int { frameWidth }
    public var outputHeight: Int { exportsFeedCut ? Self.even(Double(frameWidth) * 5 / 4) : frameHeight }

    /// The exported frame's shape, e.g. "9:16", "4:5".
    public var outputAspectLabel: String { exportsFeedCut ? "4:5" : aspectLabel }

    public static let vertical1080 = ExportSettings()

    /// Wider than tall: 16:9 rather than the default 9:16.
    public var isLandscape: Bool { width > height }

    /// The same settings turned to landscape (16:9) or portrait (9:16).
    public func oriented(landscape: Bool) -> ExportSettings {
        guard landscape != isLandscape else { return self }
        var turned = self
        (turned.width, turned.height) = (height, width)
        return turned
    }

    public var aspectLabel: String {
        if width * 16 == height * 9 { return "9:16" }
        if width * 9 == height * 16 { return "16:9" }
        return "\(width):\(height)"
    }
}

// MARK: - Project

public enum ProjectError: Error, Equatable {
    case unsupportedSchema(Int)
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    /// 2 added sound lanes, gaps between clips and stacked video lanes. A project with none of
    /// them is still written as 1, so builds from before them keep opening it; one with any is
    /// written as 2, which those builds refuse rather than open and lose them on saving.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var sources: [SourceAsset]
    public var clips: [TimelineClip]
    public var referenceAudio: AudioTrack?
    /// The audio lanes under the music, each holding sounds placed in time.
    public var soundTracks: [SoundTrack]
    /// The video lanes above the sequence, lowest first, each holding clips placed in time.
    public var videoLayers: [VideoLayer]
    /// The recorded music curve (Phase 3), in composition time. Clip curves live on the clips.
    public var automation: Automation
    public var loop: LoopRange?
    public var exportSettings: ExportSettings
    /// The EQ on the whole mix.
    public var masterEQ: MasterEQ

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.schemaVersion = Project.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.sources = []
        self.clips = []
        self.referenceAudio = nil
        self.soundTracks = []
        self.videoLayers = []
        self.automation = Automation()
        self.loop = nil
        self.exportSettings = .vertical1080
        self.masterEQ = .flat
    }

    // Tolerant decoding: new optional fields can be added without breaking old files.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, modifiedAt, sources, clips
        case referenceAudio, soundTracks, videoLayers, automation, loop, exportSettings, masterEQ
    }

    /// The oldest schema that holds everything in the project: 2 for sound lanes, gaps between
    /// clips or stacked video lanes, which version 1 builds would drop.
    public var minimumSchemaVersion: Int {
        soundTracks.isEmpty && videoLayers.isEmpty && clips.allSatisfy { $0.gap == .zero } ? 1 : 2
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minimumSchemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(sources, forKey: .sources)
        try c.encode(clips, forKey: .clips)
        try c.encodeIfPresent(referenceAudio, forKey: .referenceAudio)
        if !soundTracks.isEmpty { try c.encode(soundTracks, forKey: .soundTracks) }
        if !videoLayers.isEmpty { try c.encode(videoLayers, forKey: .videoLayers) }
        try c.encode(automation, forKey: .automation)
        try c.encodeIfPresent(loop, forKey: .loop)
        try c.encode(exportSettings, forKey: .exportSettings)
        try c.encode(masterEQ, forKey: .masterEQ)
    }

    /// Keys older files wrote that are no longer stored.
    private enum LegacyKeys: String, CodingKey {
        /// Before Phase 2.1 one level applied to every clip; it now seeds each clip's own level.
        case clipAudioVolume
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
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let level = try legacy.decodeIfPresent(Float.self, forKey: .clipAudioVolume), level != 1 {
            for i in clips.indices { clips[i].volume = min(max(clips[i].volume * level, 0), 1) }
        }
        referenceAudio = try c.decodeIfPresent(AudioTrack.self, forKey: .referenceAudio)
        // Version 1 had no sound lanes.
        soundTracks = try c.decodeIfPresent([SoundTrack].self, forKey: .soundTracks) ?? []
        // Before the music could move between lanes it had one of its own over the sounds: it
        // keeps the first lane and the sounds move down one, so nothing lands on it.
        if referenceAudio != nil, referenceAudio?.lane == nil {
            if !soundTracks.isEmpty { soundTracks.insert(SoundTrack(), at: 0) }
            referenceAudio?.lane = 0
        }
        videoLayers = try c.decodeIfPresent([VideoLayer].self, forKey: .videoLayers) ?? []
        // Older files wrote an always-empty `volumeAutomation` array; it is ignored.
        automation = try c.decodeIfPresent(Automation.self, forKey: .automation) ?? Automation()
        loop = try c.decodeIfPresent(LoopRange.self, forKey: .loop)
        exportSettings = try c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? .vertical1080
        masterEQ = try c.decodeIfPresent(MasterEQ.self, forKey: .masterEQ) ?? .flat
        // Phase 3 builds kept the clip curve project-wide in composition time; hand it to the clips.
        if let old = try c.decodeIfPresent(LegacyAutomation.self, forKey: .automation)?.clipAudio {
            for pass in old.segments { writeClipLevel(pass) }
        }
    }

    private struct LegacyAutomation: Decodable {
        var clipAudio: AutomationLane?
    }

    public func source(id: UUID) -> SourceAsset? { sources.first { $0.id == id } }
    public func source(for clip: TimelineClip) -> SourceAsset? { source(id: clip.sourceID) }
    public func clip(id: UUID) -> TimelineClip? { clips.first { $0.id == id } }
    public func index(ofClip id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    public var duration: MediaTime {
        clips.reduce(MediaTime.zero) { $0 + $1.gap + $1.compositionDuration }
    }
}
