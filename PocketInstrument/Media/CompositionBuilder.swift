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
    static func build(
        project: Project,
        renderSize: CGSize,
        frameRate: Int32,
        includeClipAudio: Bool,
        includeMusic: Bool,
        mediaURL: (SourceAsset) -> URL?,
        musicURL: URL?
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
        var cursor = CMTime.zero
        var insertedAudio = false

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
                let audioRange = sourceRange.intersection(audioTrackRange)
                if audioRange.isValid && !audioRange.isEmpty {
                    try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: cursor)
                    if clip.speed != 1 {
                        audioTrack.scaleTimeRange(
                            CMTimeRange(start: cursor, duration: audioRange.duration),
                            toDuration: CMTimeMultiplyByFloat64(audioRange.duration, multiplier: 1 / clip.speed))
                    }
                    insertedAudio = true
                }
            }

            let (naturalSize, preferred) = try await sourceVideo.load(.naturalSize, .preferredTransform)
            layer.setTransform(
                framingTransform(
                    naturalSize: naturalSize, preferred: preferred,
                    renderSize: renderSize, framing: clip.framing),
                at: cursor)
            cursor = cursor + compDuration
        }

        if let audioTrack, !insertedAudio { composition.removeTrack(audioTrack) }
        let clipAudioTrackID = insertedAudio ? audioTrack?.trackID : nil

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
            audioMix: audioMix(project: project, clipAudioTrackID: clipAudioTrackID, musicTrackID: musicTrackID),
            duration: cursor, clipAudioTrackID: clipAudioTrackID, musicTrackID: musicTrackID)
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
    static func audioMix(
        project: Project, clipAudioTrackID: CMPersistentTrackID?, musicTrackID: CMPersistentTrackID?,
        clipLevel: (id: UUID, volume: Float)? = nil, musicLevel: Float? = nil,
        writing: (target: AutomationTarget, level: Float)? = nil
    ) -> AVAudioMix? {
        var mixed = project
        if let clipLevel, let i = mixed.index(ofClip: clipLevel.id) { mixed.clips[i].volume = clipLevel.volume }
        if let musicLevel { mixed.referenceAudio?.volume = musicLevel }

        let tracks: [(CMPersistentTrackID?, AutomationTarget)] = [
            (clipAudioTrackID, .clipAudio), (musicTrackID, .music),
        ]
        let params: [AVAudioMixInputParameters] = tracks.compactMap { trackID, target in
            guard let trackID else { return nil }
            let p = AVMutableAudioMixInputParameters()
            p.trackID = trackID
            if let writing, writing.target == target {
                p.setVolume(writing.level, at: .zero)
                return p
            }
            let envelope = mixed.levelEnvelope(for: target)
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

    /// Orients the source with its preferred transform, then scales it to fill
    /// (crop) or fit (letterbox) the render frame, centred.
    static func framingTransform(
        naturalSize: CGSize, preferred: CGAffineTransform,
        renderSize: CGSize, framing: Framing
    ) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let w = abs(oriented.width)
        let h = abs(oriented.height)
        guard w > 0, h > 0 else { return .identity }
        let sx = renderSize.width / w
        let sy = renderSize.height / h
        let scale = framing == .fill ? max(sx, sy) : min(sx, sy)
        return
            preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(
                CGAffineTransform(
                    translationX: (renderSize.width - w * scale) / 2,
                    y: (renderSize.height - h * scale) / 2))
    }
}
