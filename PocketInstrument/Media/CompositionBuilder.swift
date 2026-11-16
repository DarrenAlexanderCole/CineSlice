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
    ///   - includeClipAudio: false produces a silent composition.
    static func build(
        project: Project,
        renderSize: CGSize,
        frameRate: Int32,
        includeClipAudio: Bool,
        mediaURL: (SourceAsset) -> URL?
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

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = [instruction]

        var audioMix: AVAudioMix?
        if let audioTrack, insertedAudio, project.clipAudioVolume != 1 {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(project.clipAudioVolume, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        return BuiltComposition(
            composition: composition, videoComposition: videoComposition,
            audioMix: audioMix, duration: cursor)
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
