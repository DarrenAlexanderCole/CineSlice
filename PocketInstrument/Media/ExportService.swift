import AVFoundation
import EditCore
import Photos
import UIKit
import VideoToolbox
import os

enum ExportError: LocalizedError {
    case cannotCreateSession
    case failed(String)
    case cancelled
    case photosAccessDenied

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession: return "This device can't export with the selected settings."
        case .failed(let message): return "Export failed: \(message)"
        case .cancelled: return "Export cancelled."
        case .photosAccessDenied: return "Allow \"Add Photos Only\" access in Settings to save videos."
        }
    }
}

/// AVAssetExportSession's status/progress/cancelExport are safe to touch from any thread,
/// but the class isn't annotated Sendable; this box lets the callbacks below capture it.
private struct ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
}

struct ExportResult: Equatable {
    let videoURL: URL
    /// `<video>.sync.json` next to the video, written whenever the project has reference music.
    let syncNoteURL: URL?
    let syncNote: MusicSyncNote?
}

/// Renders the project with the same CompositionBuilder the preview uses.
/// Output: MP4 at the project's export size, frame rate, codec and bitrates (default 1080×1920,
/// 30 fps, H.264 at an automatic bitrate; 1080×1350 cut to the feed), with the sound chosen by
/// `Project.exportSoundPolicy`. Encoded with AVAssetReader → AVAssetWriter, since
/// AVAssetExportSession's presets can't be given a bitrate.
enum ExportService {
    static func export(
        project: Project, store: ProjectStore,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> ExportResult {
        let settings = project.exportSettings
        let policy = project.exportSoundPolicy
        let built = try await CompositionBuilder.build(
            project: project,
            renderSize: CGSize(width: settings.outputWidth, height: settings.outputHeight),
            frameSize: CGSize(width: settings.frameWidth, height: settings.frameHeight),
            frameRate: Int32(settings.frameRate),
            includeClipAudio: policy.includesClipAudio,
            includeMusic: policy.includesMusic,
            mediaURL: { source in
                store.isMissing(source, projectID: project.id)
                    ? nil : store.mediaURL(for: source, projectID: project.id)
            },
            musicURL: project.referenceAudio.flatMap { store.audioURL(for: $0, projectID: project.id) },
            soundURL: { store.soundURL(for: $0, projectID: project.id) },
            clipStems: { store.stemURLs(for: $0, source: $1, projectID: project.id) },
            equalizer: project.masterEQ.isActive ? MasterEQTaps(EQSettings(project.masterEQ)) : nil)

        let folder = store.exportsDirectory(for: project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = project.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let stamp = Int(Date().timeIntervalSince1970)
        let url = folder.appendingPathComponent("\(safeName.isEmpty ? "Export" : safeName)-\(stamp).mp4")
        try? FileManager.default.removeItem(at: url)

        do {
            let encoder = try await Encoder(built: built, settings: settings, url: url)
            try await encoder.run(progress: progress)
        } catch {
            // A cancelled or failed render leaves no half-written file behind.
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        // Only report success if the file really exists and is non-empty.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw ExportError.failed("No output file was written.") }

        var noteURL: URL?
        let note = MusicSyncNote(project: project, exportFilename: url.lastPathComponent)
        if let note {
            let sidecar = url.deletingPathExtension().appendingPathExtension("sync.json")
            try note.jsonData.write(to: sidecar, options: .atomic)
            noteURL = sidecar
        }
        await progress(1)
        return ExportResult(videoURL: url, syncNoteURL: noteURL, syncNote: note)
    }

    /// The writer's picture settings: codec, size, SDR Rec. 709 (as AVAssetExportSession's H.264
    /// presets gave), bitrate and keyframe spacing.
    static func videoSettings(_ settings: ExportSettings) -> [String: Any] {
        let keyframeFrames = max(1, Int((settings.keyframeInterval * Double(settings.frameRate)).rounded()))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.effectiveVideoBitrate,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: keyframeFrames,
            AVVideoMaxKeyFrameIntervalDurationKey: settings.keyframeInterval,
            AVVideoAllowFrameReorderingKey: true,
        ]
        switch settings.codec {
        case .h264: compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.outputWidth,
            AVVideoHeightKey: settings.outputHeight,
            AVVideoColorPropertiesKey: rec709,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static let rec709: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// One render: reads the composited frames and mixed sound, and feeds the writer.
    /// AVAssetReader/Writer are thread-safe for this use (each input is pulled on its own queue)
    /// but not annotated Sendable.
    private final class Encoder: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoOutput: AVAssetReaderVideoCompositionOutput
        let videoInput: AVAssetWriterInput
        let audio: (output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
        let duration: CMTime
        /// Seconds of picture written so far, read for progress.
        private let written = OSAllocatedUnfairLock(initialState: 0.0)

        init(built: BuiltComposition, settings: ExportSettings, url: URL) async throws {
            let asset = built.composition
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            duration = built.duration

            let composition = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            videoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ])
            videoOutput.videoComposition = composition
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else { throw ExportError.cannotCreateSession }
            reader.add(videoOutput)

            let videoSettings = ExportService.videoSettings(settings)
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw ExportError.cannotCreateSession
            }
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { throw ExportError.cannotCreateSession }
            writer.add(videoInput)

            // A silent export has no audio tracks at all, so there's no mix to apply.
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                audio = nil
            } else {
                let output = AVAssetReaderAudioMixOutput(
                    audioTracks: audioTracks,
                    audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ])
                output.audioMix = built.audioMix
                output.alwaysCopiesSampleData = false
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: settings.audioBitrate,
                    ])
                input.expectsMediaDataInRealTime = false
                guard reader.canAdd(output), writer.canAdd(input) else { throw ExportError.cannotCreateSession }
                reader.add(output)
                writer.add(input)
                audio = (output, input)
            }
        }

        /// Encodes to the end; cancelling the calling task cancels the render.
        func run(progress: @escaping @MainActor (Double) -> Void) async throws {
            let poller = Task { @MainActor [written, duration] in
                while !Task.isCancelled {
                    progress(min(0.99, written.withLock { $0 } / max(duration.seconds, 0.001)))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { poller.cancel() }

            try await withTaskCancellationHandler {
                guard reader.startReading() else {
                    throw ExportError.failed(reader.error?.localizedDescription ?? "Couldn't read the sequence.")
                }
                guard writer.startWriting() else {
                    reader.cancelReading()
                    throw ExportError.failed(writer.error?.localizedDescription ?? "Couldn't start the file.")
                }
                writer.startSession(atSourceTime: .zero)

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.pump(self.videoOutput, into: self.videoInput, isVideo: true) }
                    if let audio = self.audio {
                        group.addTask { await self.pump(audio.output, into: audio.input, isVideo: false) }
                    }
                }

                if writer.status == .failed {
                    reader.cancelReading()
                    throw ExportError.failed(writer.error?.localizedDescription ?? "Writing the file failed.")
                }
                if Task.isCancelled || reader.status == .cancelled {
                    writer.cancelWriting()
                    throw ExportError.cancelled
                }
                if reader.status == .failed {
                    writer.cancelWriting()
                    throw ExportError.failed(reader.error?.localizedDescription ?? "Reading the sequence failed.")
                }
                await writer.finishWriting()
                guard writer.status == .completed else {
                    throw ExportError.failed(writer.error?.localizedDescription ?? "Unknown error")
                }
            } onCancel: {
                self.reader.cancelReading()
            }
        }

        /// Moves samples from one reader output to its writer input until the output runs dry.
        private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, isVideo: Bool) async {
            let queue = DispatchQueue(label: "cineslice.export.\(isVideo ? "video" : "audio")")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var finished = false
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData, !finished {
                        guard self.reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        if isVideo {
                            let end = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            self.written.withLock { $0 = end }
                        }
                        if !input.append(sample) {
                            finished = true
                            self.reader.cancelReading()
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    /// Runs a configured session to completion; cancelling the calling task cancels the export.
    static func run(_ session: AVAssetExportSession) async throws {
        let box = ExportSessionBox(session: session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.session.exportAsynchronously {
                    let session = box.session
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: ExportError.cancelled)
                    default:
                        continuation.resume(
                            throwing: ExportError.failed(session.error?.localizedDescription ?? "Unknown error"))
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    /// Saves the video to Photos; returns its Photos identifier, for handing it to Instagram.
    @discardableResult
    static func saveToPhotos(_ url: URL) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photosAccessDenied }
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier =
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)?.placeholderForCreatedAsset?
                .localIdentifier
        }
        return identifier
    }

    /// Instagram's own link for opening it on a video in Photos, falling back to just opening it.
    /// nil when Instagram isn't installed.
    @MainActor
    static func instagramURL(forPhotosAsset identifier: String?) -> URL? {
        guard let app = URL(string: "instagram://app"), UIApplication.shared.canOpenURL(app) else { return nil }
        guard let identifier,
            let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            let library = URL(string: "instagram://library?LocalIdentifier=\(encoded)")
        else { return app }
        return library
    }
}
