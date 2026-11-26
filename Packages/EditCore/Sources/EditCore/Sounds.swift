import Foundation

// MARK: - Sound tracks

/// A stretch of a sound file placed at a time on one of the audio lanes under the music: an
/// effect, a voice-over, a room tone. Unlike the sequence's clips, sounds sit where they're put,
/// with gaps between them. The file lives in the project's Media folder and is never modified.
public struct SoundClip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The file in the project's Media folder.
    public var fileName: String
    public var originalFilename: String?
    /// The whole file's length.
    public var fileDuration: MediaTime
    /// The part of the file that plays, in file time.
    public var sourceRange: MediaTimeRange
    /// Where it starts on the composition timeline (never before 0).
    public var start: MediaTime
    /// Its level, 0…1.
    public var volume: Float
    /// How long it takes to rise from silence at its start, and to fall to silence at its end.
    /// Together they never run longer than the sound.
    public var fadeIn: MediaTime
    public var fadeOut: MediaTime

    public init(
        id: UUID = UUID(), fileName: String, originalFilename: String? = nil, fileDuration: MediaTime,
        sourceRange: MediaTimeRange? = nil, start: MediaTime, volume: Float = 1, fadeIn: MediaTime = .zero,
        fadeOut: MediaTime = .zero
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFilename = originalFilename
        self.fileDuration = fileDuration
        self.sourceRange = sourceRange ?? MediaTimeRange(start: .zero, duration: fileDuration)
        self.start = max(start, .zero)
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, originalFilename, fileDuration, sourceRange, start, volume, fadeIn, fadeOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        fileDuration = try c.decode(MediaTime.self, forKey: .fileDuration)
        sourceRange = try c.decode(MediaTimeRange.self, forKey: .sourceRange)
        start = try c.decode(MediaTime.self, forKey: .start)
        volume = try c.decode(Float.self, forKey: .volume)
        fadeIn = try c.decodeIfPresent(MediaTime.self, forKey: .fadeIn) ?? .zero
        fadeOut = try c.decodeIfPresent(MediaTime.self, forKey: .fadeOut) ?? .zero
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encodeIfPresent(originalFilename, forKey: .originalFilename)
        try c.encode(fileDuration, forKey: .fileDuration)
        try c.encode(sourceRange, forKey: .sourceRange)
        try c.encode(start, forKey: .start)
        try c.encode(volume, forKey: .volume)
        if fadeIn > .zero { try c.encode(fadeIn, forKey: .fadeIn) }
        if fadeOut > .zero { try c.encode(fadeOut, forKey: .fadeOut) }
    }

    /// Where it plays on the composition timeline.
    public var timelineRange: MediaTimeRange { MediaTimeRange(start: start, duration: sourceRange.duration) }

    /// Fades kept to the sound: neither below zero, and the two together no longer than it.
    mutating func clampFades() {
        let length = sourceRange.duration
        fadeIn = min(max(fadeIn, .zero), length)
        fadeOut = min(max(fadeOut, .zero), length - fadeIn)
    }

    /// Its level over its own time on the timeline: silence to `volume` across the fade in, held,
    /// then down to silence across the fade out. Points in time order; a step where there's no
    /// fade.
    public var levelPoints: [AutomationPoint] {
        let range = timelineRange
        var points = [AutomationPoint(time: range.start, value: fadeIn > .zero ? 0 : volume)]
        if fadeIn > .zero { points.append(AutomationPoint(time: range.start + fadeIn, value: volume)) }
        if fadeOut > .zero { points.append(AutomationPoint(time: range.end - fadeOut, value: volume)) }
        points.append(AutomationPoint(time: range.end, value: fadeOut > .zero ? 0 : volume))
        return points
    }
}

/// One audio lane of sounds, under the music. Sounds on a lane never overlap; on different
/// lanes they play together.
public struct SoundTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Sounds in time order.
    public var clips: [SoundClip]
    public var isMuted: Bool

    public init(id: UUID = UUID(), clips: [SoundClip] = [], isMuted: Bool = false) {
        self.id = id
        self.clips = clips.sorted { $0.start < $1.start }
        self.isMuted = isMuted
    }

    /// Whether `range` is clear of every sound here but `excluding`.
    public func fits(_ range: MediaTimeRange, excluding: UUID? = nil) -> Bool {
        clips.allSatisfy { clip in
            clip.id == excluding || clip.timelineRange.end <= range.start || clip.timelineRange.start >= range.end
        }
    }

    /// The lane's level over the timeline for the player: each sound's level and fades, silence
    /// between sounds, and silence throughout when the lane is muted. Points in time order; two at
    /// the same time make a step.
    public var levelEnvelope: [AutomationPoint] {
        guard !isMuted else { return [AutomationPoint(time: .zero, value: 0)] }
        var points = [AutomationPoint(time: .zero, value: 0)]
        for clip in clips {
            // Silent up to the sound: a step down at the last one's end, held to this one's start.
            if let last = points.last, last.time < clip.start {
                if last.value != 0 { points.append(AutomationPoint(time: last.time, value: 0)) }
                points.append(AutomationPoint(time: clip.start, value: 0))
            }
            for point in clip.levelPoints where point != points.last { points.append(point) }
        }
        return points
    }

    mutating func insert(_ clip: SoundClip) {
        let at = clips.firstIndex { $0.start > clip.start } ?? clips.count
        clips.insert(clip, at: at)
    }
}

extension Project {
    /// LIGHTBOX's audio lanes: always this many, empty or not, shared by the sounds and the music.
    public static let maxSoundTracks = 10

    public func sound(id: UUID) -> SoundClip? {
        for track in soundTracks { if let clip = track.clips.first(where: { $0.id == id }) { return clip } }
        return nil
    }

    /// The lane and position of a sound.
    public func soundLocation(id: UUID) -> (track: Int, index: Int)? {
        for (t, track) in soundTracks.enumerated() {
            if let i = track.clips.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    /// Whether `range` is clear on audio lane `lane`: of its sounds but `excludingSound`, and of
    /// the music, if it sits there, unless `excludingMusic`.
    public func audioLaneFits(
        _ range: MediaTimeRange, lane: Int, excludingSound: UUID? = nil, excludingMusic: Bool = false
    ) -> Bool {
        guard lane >= 0, lane < Self.maxSoundTracks else { return false }
        if !excludingMusic, let music = referenceAudio, music.audioLane == lane {
            let song = music.timelineRange
            if song.start < range.end && range.start < song.end { return false }
        }
        return lane >= soundTracks.count || soundTracks[lane].fits(range, excluding: excludingSound)
    }

    /// Whether a sound of `range` could go on lane `track`.
    public func soundFits(_ range: MediaTimeRange, onTrack track: Int, excluding: UUID? = nil) -> Bool {
        audioLaneFits(range, lane: track, excludingSound: excluding)
    }

    /// The first audio lane from `from` up where `range` is clear.
    public func firstClearAudioLane(
        for range: MediaTimeRange, from: Int = 0, excludingSound: UUID? = nil, excludingMusic: Bool = false
    ) -> Int? {
        (max(0, from)..<Self.maxSoundTracks).first {
            audioLaneFits(range, lane: $0, excludingSound: excludingSound, excludingMusic: excludingMusic)
        }
    }

    /// Lane `lane` exists to put a sound on (lanes are numbered by place, so the ones before it
    /// are made too, empty).
    mutating func ensureSoundTrack(_ lane: Int) {
        while soundTracks.count <= lane { soundTracks.append(SoundTrack()) }
    }

    /// Empty lanes at the end aren't kept; every lane always shows, so nothing moves.
    mutating func pruneSoundTracks() {
        while soundTracks.last?.clips.isEmpty == true { soundTracks.removeLast() }
    }
}

/// Places a new sound on the first lane from `preferredTrack` on where it's clear, music
/// included; refused when none of them is.
public struct AddSoundCommand: EditingCommand {
    public let clip: SoundClip
    public let preferredTrack: Int

    public init(clip: SoundClip, preferredTrack: Int = 0) {
        self.clip = clip
        self.preferredTrack = preferredTrack
    }

    public var actionName: String { "Add Sound" }

    public func apply(to project: inout Project) throws {
        guard let lane = project.firstClearAudioLane(for: clip.timelineRange, from: preferredTrack) else {
            throw EditError.noRoom
        }
        project.ensureSoundTrack(lane)
        project.soundTracks[lane].insert(clip)
    }
}

/// Moves a sound to a new time and lane. Refused if it would overlap a sound or the music there.
public struct MoveSoundCommand: EditingCommand {
    public let clipID: UUID
    public let track: Int
    public let start: MediaTime

    public init(clipID: UUID, track: Int, start: MediaTime) {
        self.clipID = clipID
        self.track = track
        self.start = max(start, .zero)
    }

    public var actionName: String { "Move Sound" }

    public func apply(to project: inout Project) throws {
        guard let at = project.soundLocation(id: clipID) else { throw EditError.clipNotFound }
        var clip = project.soundTracks[at.track].clips[at.index]
        clip.start = start
        guard project.soundFits(clip.timelineRange, onTrack: track, excluding: clipID) else { throw EditError.noRoom }
        project.soundTracks[at.track].clips.remove(at: at.index)
        project.ensureSoundTrack(track)
        project.soundTracks[track].insert(clip)
        project.pruneSoundTracks()
    }
}

/// Cuts a sound in two at a composition time; the second half gets `newClipID`.
public struct SplitSoundCommand: EditingCommand {
    public let clipID: UUID
    public let time: MediaTime
    public let newClipID: UUID

    public init(clipID: UUID, time: MediaTime, newClipID: UUID = UUID()) {
        self.clipID = clipID
        self.time = time
        self.newClipID = newClipID
    }

    public var actionName: String { "Split Sound" }

    /// Whether a cut at `time` leaves two halves long enough to keep.
    public static func canSplit(_ clip: SoundClip, at time: MediaTime) -> Bool {
        time - clip.start >= minimumClipDuration && clip.timelineRange.end - time >= minimumClipDuration
    }

    public func apply(to project: inout Project) throws {
        guard let at = project.soundLocation(id: clipID) else { throw EditError.clipNotFound }
        let clip = project.soundTracks[at.track].clips[at.index]
        guard Self.canSplit(clip, at: time) else { throw EditError.invalidRange }
        let cut = clip.sourceRange.start + (time - clip.start)
        // The fade in stays with the first half and the fade out with the second.
        var first = clip
        first.sourceRange = MediaTimeRange(start: clip.sourceRange.start, end: cut)
        first.fadeOut = .zero
        first.clampFades()
        var second = clip
        second.id = newClipID
        second.start = time
        second.sourceRange = MediaTimeRange(start: cut, end: clip.sourceRange.end)
        second.fadeIn = .zero
        second.clampFades()
        project.soundTracks[at.track].clips[at.index] = first
        project.soundTracks[at.track].clips.insert(second, at: at.index + 1)
    }
}

/// Takes a sound off its lane (its file stays in the project).
public struct RemoveSoundCommand: EditingCommand {
    public let clipID: UUID
    public init(clipID: UUID) { self.clipID = clipID }
    public var actionName: String { "Remove Sound" }

    public func apply(to project: inout Project) throws {
        guard let at = project.soundLocation(id: clipID) else { throw EditError.clipNotFound }
        project.soundTracks[at.track].clips.remove(at: at.index)
        project.pruneSoundTracks()
    }
}

/// Sets a sound's level, 0…1.
public struct SetSoundLevelCommand: EditingCommand {
    public let clipID: UUID
    public let volume: Float

    public init(clipID: UUID, volume: Float) {
        self.clipID = clipID
        self.volume = volume
    }

    public var actionName: String { "Sound Level" }

    public func apply(to project: inout Project) throws {
        guard let at = project.soundLocation(id: clipID) else { throw EditError.clipNotFound }
        project.soundTracks[at.track].clips[at.index].volume = min(max(volume, 0), 1)
    }
}

/// Sets a sound's fade in and fade out, kept within the sound.
public struct SetSoundFadesCommand: EditingCommand {
    public let clipID: UUID
    public let fadeIn: MediaTime
    public let fadeOut: MediaTime

    public init(clipID: UUID, fadeIn: MediaTime, fadeOut: MediaTime) {
        self.clipID = clipID
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var actionName: String { "Sound Fades" }

    public func apply(to project: inout Project) throws {
        guard let at = project.soundLocation(id: clipID) else { throw EditError.clipNotFound }
        var clip = project.soundTracks[at.track].clips[at.index]
        clip.fadeIn = fadeIn
        clip.fadeOut = fadeOut
        clip.clampFades()
        project.soundTracks[at.track].clips[at.index] = clip
    }
}

/// Mutes or unmutes a whole sound lane.
public struct SetSoundTrackMuteCommand: EditingCommand {
    public let trackID: UUID
    public let isMuted: Bool

    public init(trackID: UUID, isMuted: Bool) {
        self.trackID = trackID
        self.isMuted = isMuted
    }

    public var actionName: String { isMuted ? "Mute Lane" : "Unmute Lane" }

    public func apply(to project: inout Project) throws {
        guard let t = project.soundTracks.firstIndex(where: { $0.id == trackID }) else {
            throw EditError.clipNotFound
        }
        project.soundTracks[t].isMuted = isMuted
    }
}

/// Slides the music to a new start and puts it on audio lane `lane`. Refused if the song is
/// locked, or would overlap a sound there.
public struct PlaceMusicCommand: EditingCommand {
    public let lane: Int
    public let offset: MediaTime

    public init(lane: Int, offset: MediaTime) {
        self.lane = lane
        self.offset = offset
    }

    public var actionName: String { "Move Music" }

    public func apply(to project: inout Project) throws {
        guard var music = project.referenceAudio else { throw EditError.sourceNotFound }
        guard !music.isLocked else { throw EditError.locked }
        music.offset = music.clampedOffset(offset, sequenceDuration: project.duration)
        guard project.audioLaneFits(music.timelineRange, lane: lane, excludingMusic: true) else {
            throw EditError.noRoom
        }
        music.lane = lane
        project.referenceAudio = music
    }
}
