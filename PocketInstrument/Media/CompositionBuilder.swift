import AVFoundation
import CoreGraphics
import EditCore

/// The single source of truth for turning a `Project` into AVFoundation objects.
/// Preview and export both call `build`, so what you watch is what you export.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
    /// Track IDs for re-mixing levels on the live player item without a rebuild.
    let clipAudioTrackID: CMPersistentTrackID?
    let musicTrackID: CMPersistentTrackID?
    /// The voices of split clips; their scene plays on the clip audio track.
    let voiceTrackID: CMPersistentTrackID?
    /// Clips playing split sound. A clip whose split isn't made yet is silent.
    let separatedClipIDs: Set<UUID>
}

enum CompositionError: LocalizedError {
    case empty
    case cannotCreateTrack

    var errorDescription: String? {
        switch self {
        case .empty: return "Add at least one clip first."
        case .cannotCreateTrack: return "Couldn't create a composition track."
        }
    }
}

enum CompositionBuilder {
    /// - Parameters:
    ///   - mediaURL: resolves a source to its file; return nil when the file is missing.
    ///   - includeClipAudio / includeMusic: both false produces a silent composition.
    ///   - musicURL: the reference music file, or nil when there's none or it's missing.
    ///   - clipStems: a clip's split sound (see `VoiceSeparator`), each half starting where the
    ///     source's sound starts: the scene plays instead of the source's sound, the voices on a
    ///     track of their own, each at the clip's level for it. Nil plays the source's own sound.
    ///   - frameSize: the frame the clips are framed and cropped in, when the output keeps only
    ///     its centre (the feed's 4:5 of a 9:16 sequence); nil means `renderSize`.
    static func build(
        project: Project,
        renderSize: CGSize,
        frameSize: CGSize? = nil,
        frameRate: Int32,
        includeClipAudio: Bool,
        includeMusic: Bool,
        mediaURL: (SourceAsset) -> URL?,
        musicURL: URL?,
        clipStems: (TimelineClip, SourceAsset) -> (voice: URL, scene: URL)? = { _, _ in nil },
        equalizer: MasterEQTaps? = nil
    ) async throws -> BuiltComposition {
        guard !project.clips.isEmpty else { throw CompositionError.empty }

        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.cannotCreateTrack }
        let audioTrack: AVMutableCompositionTrack? =
            includeClipAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let frame = frameSize ?? renderSize
        // Centres the frame on the output, cutting what overhangs.
        let toOutput = CGAffineTransform(
            translationX: (renderSize.width - frame.width) / 2, y: (renderSize.height - frame.height) / 2)
        var cursor = CMTime.zero
        var insertedAudio = false
        var voiceTrack: AVMutableCompositionTrack?
        var separated: Set<UUID> = []

        for clip in project.clips {
            let compDuration = clip.compositionDuration.cmTime
            let sourceRange = clip.sourceRange.cmTimeRange

            guard let source = project.source(for: clip),
                let url = mediaURL(source)
            else {
                // Missing media keeps its slot as black so timing never shifts.
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: compDuration))
                cursor = cursor + compDuration
                continue
            }

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: compDuration))
                cursor = cursor + compDuration
                continue
            }

            // Some files' video track is slightly shorter than the asset; insert what
            // exists and pad with black so every clip keeps its exact model duration.
            let videoRange = try await sourceVideo.load(.timeRange)
            let usable = sourceRange.intersection(videoRange)
            let usableDuration = (usable.isValid && !usable.isEmpty) ? usable.duration : .zero
            if usableDuration > .zero {
                try videoTrack.insertTimeRange(usable, of: sourceVideo, at: cursor)
            }
            let shortfall = sourceRange.duration - usableDuration
            if shortfall > .zero {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor + usableDuration, duration: shortfall))
            }
            if clip.speed != 1 {
                videoTrack.scaleTimeRange(
                    CMTimeRange(start: cursor, duration: sourceRange.duration),
                    toDuration: compDuration)
            }

            if let audioTrack, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioTrackRange = try await sourceAudio.load(.timeRange)
                var audioRange = sourceRange.intersection(audioTrackRange)
                if audioRange.isValid && !audioRange.isEmpty {
                    let stemAssets = clipStems(clip, source).map {
                        (voice: AVURLAsset(url: $0.voice, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]),
                         scene: AVURLAsset(url: $0.scene, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
                    }
                    // `stemAssets` must outlive the inserts: a track whose asset is gone fails with -11800.
                    if let scene = try? await stemAssets?.scene.loadTracks(withMediaType: .audio).first,
                        let voice = try? await stemAssets?.voice.loadTracks(withMediaType: .audio).first,
                        let voices = voiceTrack
                            ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    {
                        voiceTrack = voices
                        // The split files start at the source sound's first sample.
                        let offset = audioTrackRange.start
                        let wanted = CMTimeRange(start: audioRange.start - offset, duration: audioRange.duration)
                        let usable = wanted
                            .intersection(try await scene.load(.timeRange))
                            .intersection(try await voice.load(.timeRange))
                        audioRange = CMTimeRange(start: usable.start + offset, duration: usable.duration)
                        if usable.isValid && !usable.isEmpty {
                            try audioTrack.insertTimeRange(usable, of: scene, at: cursor)
                            try voices.insertTimeRange(usable, of: voice, at: cursor)
                            separated.insert(clip.id)
                        }
                    } else {
                        try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: cursor)
                    }
                }
                if audioRange.isValid && !audioRange.isEmpty {
                    if clip.speed != 1 {
                        let range = CMTimeRange(start: cursor, duration: audioRange.duration)
                        let scaled = CMTimeMultiplyByFloat64(audioRange.duration, multiplier: 1 / clip.speed)
                        audioTrack.scaleTimeRange(range, toDuration: scaled)
                        if separated.contains(clip.id) { voiceTrack?.scaleTimeRange(range, toDuration: scaled) }
                    }
                    insertedAudio = true
                }
            }

            let (naturalSize, preferred) = try await sourceVideo.load(.naturalSize, .preferredTransform)
            layer.setTransform(
                framingTransform(
                    naturalSize: naturalSize, preferred: preferred,
                    renderSize: frame, framing: clip.framing, crop: clip.crop
                ).concatenating(toOutput),
                at: cursor)
            cursor = cursor + compDuration
        }

        if let audioTrack, !insertedAudio { composition.removeTrack(audioTrack) }
        let clipAudioTrackID = insertedAudio ? audioTrack?.trackID : nil
        if let voiceTrack, separated.isEmpty { composition.removeTrack(voiceTrack) }
        let voiceTrackID = separated.isEmpty ? nil : voiceTrack?.trackID

        var musicTrackID: CMPersistentTrackID?
        if includeMusic, let music = project.referenceAudio, let musicURL {
            musicTrackID = try await insertMusic(
                music, url: musicURL, sequenceDuration: MediaTime(cursor), into: composition)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = [instruction]

        return BuiltComposition(
            composition: composition, videoComposition: videoComposition,
            audioMix: audioMix(
                project: project, clipAudioTrackID: clipAudioTrackID, musicTrackID: musicTrackID,
                voiceTrackID: voiceTrackID, separated: separated, equalizer: equalizer),
            duration: cursor, clipAudioTrackID: clipAudioTrackID, musicTrackID: musicTrackID,
            voiceTrackID: voiceTrackID, separatedClipIDs: separated)
    }

    /// Places the music per `MusicPlacement`, trimmed to the sequence. Returns its track ID, or nil if nothing overlaps.
    private static func insertMusic(
        _ music: AudioTrack, url: URL, sequenceDuration: MediaTime, into composition: AVMutableComposition
    ) async throws -> CMPersistentTrackID? {
        guard let placement = MusicPlacement(track: music, sequenceDuration: sequenceDuration) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
            let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let wanted = CMTimeRange(
            start: placement.audioStart.cmTime, duration: placement.compositionRange.duration.cmTime)
        let usable = wanted.intersection(try await source.load(.timeRange))
        guard usable.isValid, !usable.isEmpty else {
            composition.removeTrack(track)
            return nil
        }
        let at = placement.compositionRange.start.cmTime + (usable.start - wanted.start)
        try track.insertTimeRange(usable, of: source, at: at)
        return track.trackID
    }

    /// Levels for each audio track: the project's level envelopes (static levels, each clip's
    /// own level from its first frame, and recorded automation) as volume ramps. Shared by
    /// preview and export. Cheap, so the player's mix can be swapped while a fader moves:
    /// `clipLevel`/`musicLevel` replace the static levels for live fader previews; recorded
    /// automation still wins where it exists. `writing` plays one track at a fader's level
    /// throughout, while that fader is being recorded.
    ///
    /// Split clips (`separated`) play their scene on the clip audio track and their voices on
    /// `voiceTrackID`, each scaled by the clip's level for it; clips set to split whose split isn't
    /// made yet are silent. `balance` replaces one clip's levels for a live fader preview.
    ///
    /// `equalizer` runs the master EQ on every track, reading its settings as it plays; pass the same
    /// one each time an item's mix is replaced, so its taps carry over.
    static func audioMix(
        project: Project, clipAudioTrackID: CMPersistentTrackID?, musicTrackID: CMPersistentTrackID?,
        voiceTrackID: CMPersistentTrackID? = nil, separated: Set<UUID> = [],
        clipLevel: (id: UUID, volume: Float)? = nil, musicLevel: Float? = nil,
        balance: (id: UUID, balance: SoundBalance)? = nil,
        writing: (target: AutomationTarget, level: Float)? = nil,
        equalizer: MasterEQTaps? = nil
    ) -> AVAudioMix? {
        var mixed = project
        if let clipLevel, let i = mixed.index(ofClip: clipLevel.id) { mixed.clips[i].volume = clipLevel.volume }
        if let musicLevel { mixed.referenceAudio?.volume = musicLevel }
        if let balance, let i = mixed.index(ofClip: balance.id) { mixed.clips[i].balance = balance.balance }

        // A clip waiting for its split is silent rather than heard as recorded, voice and all.
        let scene: (TimelineClip) -> Float = { clip in
            guard let balance = clip.balance else { return 1 }
            return separated.contains(clip.id) ? balance.scene : 0
        }
        let voice: (TimelineClip) -> Float = { separated.contains($0.id) ? $0.balance?.voice ?? 0 : 0 }
        let anySplit = mixed.clips.contains { $0.balance != nil }
        let tracks: [(CMPersistentTrackID?, AutomationTarget, ((TimelineClip) -> Float)?)] = [
            (clipAudioTrackID, .clipAudio, anySplit ? scene : nil),
            (voiceTrackID, .clipAudio, voice),
            (musicTrackID, .music, nil),
        ]
        let params: [AVAudioMixInputParameters] = tracks.compactMap { trackID, target, gain in
            guard let trackID else { return nil }
            let p = AVMutableAudioMixInputParameters()
            p.trackID = trackID
            p.audioTapProcessor = equalizer?.tap(for: trackID)
            if let writing, writing.target == target {
                if let gain {
                    for entry in SequenceMap(project: mixed).entries {
                        guard let clip = mixed.clip(id: entry.clipID) else { continue }
                        p.setVolume(writing.level * gain(clip), at: entry.compositionRange.start.cmTime)
                    }
                } else {
                    p.setVolume(writing.level, at: .zero)
                }
                return p
            }
            let envelope = mixed.levelEnvelope(for: target, gain: gain)
            for (a, b) in zip(envelope, envelope.dropFirst()) where b.time > a.time {
                if a.value == b.value {
                    p.setVolume(a.value, at: a.time.cmTime)
                } else {
                    p.setVolumeRamp(
                        fromStartVolume: a.value, toEndVolume: b.value,
                        timeRange: CMTimeRange(start: a.time.cmTime, end: b.time.cmTime))
                }
            }
            return p
        }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    /// What Explore plays, in source time: the source itself, or, when its sound has been split,
    /// its picture with the two halves at `balance`'s levels; silent while a split is wanted but
    /// not made yet.
    static func sourceItem(url: URL, stems: (voice: URL, scene: URL)?, balance: SoundBalance?) async -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let balance else { return AVPlayerItem(asset: asset) }
        guard let stems else {
            let item = AVPlayerItem(asset: asset)
            if let sound = try? await asset.loadTracks(withMediaType: .audio).first {
                let p = AVMutableAudioMixInputParameters(track: sound)
                p.setVolume(0, at: .zero)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [p]
                item.audioMix = mix
            }
            return item
        }
        do {
            let voiceAsset = AVURLAsset(url: stems.voice, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let sceneAsset = AVURLAsset(url: stems.scene, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let video = try await asset.loadTracks(withMediaType: .video).first,
                let sound = try await asset.loadTracks(withMediaType: .audio).first,
                let voice = try await voiceAsset.loadTracks(withMediaType: .audio).first,
                let scene = try await sceneAsset.loadTracks(withMediaType: .audio).first
            else { return AVPlayerItem(asset: asset) }
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                let voiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                let sceneTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return AVPlayerItem(asset: asset) }
            let videoRange = try await video.load(.timeRange)
            try videoTrack.insertTimeRange(videoRange, of: video, at: videoRange.start)
            videoTrack.preferredTransform = try await video.load(.preferredTransform)
            // The split files start at the source sound's first sample.
            let offset = try await sound.load(.timeRange).start
            try voiceTrack.insertTimeRange(try await voice.load(.timeRange), of: voice, at: offset)
            try sceneTrack.insertTimeRange(try await scene.load(.timeRange), of: scene, at: offset)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [(voiceTrack, balance.voice), (sceneTrack, balance.scene)].map { track, level in
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(level, at: .zero)
                return p
            }
            let item = AVPlayerItem(asset: composition)
            item.audioMix = mix
            return item
        } catch {
            return AVPlayerItem(asset: asset)
        }
    }

    /// Orients the source with its preferred transform, then scales it to fill
    /// (crop) or fit (letterbox) the render frame, centred, then pushes in on `crop`.
    static func framingTransform(
        naturalSize: CGSize, preferred: CGAffineTransform,
        renderSize: CGSize, framing: Framing, crop: Crop? = nil
    ) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let w = abs(oriented.width)
        let h = abs(oriented.height)
        guard w > 0, h > 0 else { return .identity }
        let sx = renderSize.width / w
        let sy = renderSize.height / h
        let scale = framing == .fill ? max(sx, sy) : min(sx, sy)
        let push = crop ?? .full
        let framed =
            preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(
                CGAffineTransform(
                    translationX: (renderSize.width - w * scale) / 2,
                    y: (renderSize.height - h * scale) / 2))
        return
            framed
            .concatenating(
                CGAffineTransform(translationX: -push.x * renderSize.width, y: -push.y * renderSize.height)
            )
            .concatenating(CGAffineTransform(scaleX: 1 / push.size, y: 1 / push.size))
    }
}
