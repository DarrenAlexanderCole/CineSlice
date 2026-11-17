import AVFoundation
import CoreTransferable
import EditCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A movie handed over by the Photos picker. The system deletes the received
/// file after the import closure returns, so it is copied to a temp file first;
/// `ProjectStore.adoptMedia` then *moves* it into the project (one copy total).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum ImportError: LocalizedError {
    case noVideoTrack(String)
    case noAudioTrack(String)
    case protectedAudio(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let name): return "\(name) has no video track."
        case .noAudioTrack(let name): return "\(name) has no sound."
        case .protectedAudio(let name):
            return "\(name) is copy-protected (for example, an Apple Music download) and can't be used."
        case .unreadable(let name): return "Couldn't read \(name)."
        }
    }
}

enum MediaImporter {
    /// Reads duration, oriented size, frame rate and audio presence.
    static func analyze(url: URL, fileName: String, originalFilename: String?) async throws -> SourceAsset {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let label = originalFilename ?? fileName
        let duration: CMTime
        do { duration = try await asset.load(.duration) } catch { throw ImportError.unreadable(label) }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack(label)
        }
        let (size, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        return SourceAsset(
            fileName: fileName,
            originalFilename: originalFilename,
            duration: MediaTime(duration),
            width: Int(abs(oriented.width).rounded()),
            height: Int(abs(oriented.height).rounded()),
            nominalFrameRate: Double(fps),
            hasAudio: hasAudio)
    }

    /// Photos picker → project media: videos as they are, photos as still movies.
    /// Returns the sources that imported and the errors for those that didn't.
    static func importPhotos(
        _ items: [PhotosPickerItem], store: ProjectStore, projectID: UUID,
        progress: @MainActor (Int, Int) -> Void
    ) async -> ([SourceAsset], [Error]) {
        var sources: [SourceAsset] = []
        var errors: [Error] = []
        for (i, item) in items.enumerated() {
            await progress(i + 1, items.count)
            do {
                let label = "Item \(i + 1)"
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw ImportError.unreadable(label)
                    }
                    sources.append(
                        try await adopt(tempURL: movie.url, originalName: nil, store: store, projectID: projectID))
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ImportError.unreadable(label)
                    }
                    sources.append(
                        try await adoptStill(
                            imageData: data, originalName: "Photo", label: label, store: store, projectID: projectID))
                }
            } catch {
                errors.append(error)
            }
        }
        return (sources, errors)
    }

    /// Files app → project media (security-scoped URLs are copied, never moved). Images become still movies.
    static func importFiles(
        _ urls: [URL], store: ProjectStore, projectID: UUID,
        progress: @MainActor (Int, Int) -> Void
    ) async -> ([SourceAsset], [Error]) {
        var sources: [SourceAsset] = []
        var errors: [Error] = []
        for (i, url) in urls.enumerated() {
            await progress(i + 1, urls.count)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    let data = try Data(contentsOf: url)
                    sources.append(
                        try await adoptStill(
                            imageData: data, originalName: url.lastPathComponent, label: url.lastPathComponent,
                            store: store, projectID: projectID))
                    continue
                }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                try FileManager.default.copyItem(at: url, to: temp)
                sources.append(
                    try await adopt(
                        tempURL: temp, originalName: url.lastPathComponent,
                        store: store, projectID: projectID))
            } catch {
                errors.append(error)
            }
        }
        return (sources, errors)
    }

    // MARK: Reference music

    static func analyzeAudio(url: URL, fileName: String, originalFilename: String?) async throws -> AudioTrack {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let label = originalFilename ?? "That file"
        let duration: CMTime
        let isProtected: Bool
        do {
            (duration, isProtected) = try await asset.load(.duration, .hasProtectedContent)
        } catch {
            throw ImportError.unreadable(label)
        }
        guard !isProtected else { throw ImportError.protectedAudio(label) }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ImportError.noAudioTrack(label) }
        return AudioTrack(fileName: fileName, originalFilename: originalFilename, duration: MediaTime(duration))
    }

    /// Files app → project media, as-is (m4a, mp3, wav, aiff…).
    static func importAudioFile(_ url: URL, store: ProjectStore, projectID: UUID) async throws -> AudioTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: temp)
        return try await adoptAudio(
            tempURL: temp, originalName: url.lastPathComponent, store: store, projectID: projectID)
    }

    /// A video from Photos → its soundtrack only, saved as .m4a (the picture is discarded).
    static func importAudio(fromVideo item: PhotosPickerItem, store: ProjectStore, projectID: UUID) async throws
        -> AudioTrack
    {
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
            throw ImportError.unreadable("That video")
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let asset = AVURLAsset(url: movie.url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ImportError.noAudioTrack("That video")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.unreadable("That video")
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        session.outputURL = temp
        session.outputFileType = .m4a
        try await ExportService.run(session)
        return try await adoptAudio(
            tempURL: temp, originalName: "Sound from video", store: store, projectID: projectID)
    }

    static func adoptAudio(tempURL: URL, originalName: String, store: ProjectStore, projectID: UUID)
        async throws -> AudioTrack
    {
        let name = try store.adoptMedia(at: tempURL, projectID: projectID)
        let stored = store.mediaDirectory(for: projectID).appendingPathComponent(name)
        do {
            return try await analyzeAudio(url: stored, fileName: name, originalFilename: originalName)
        } catch {
            try? FileManager.default.removeItem(at: stored)
            throw error
        }
    }

    // MARK: Shared

    /// A photo → a still movie in the project's media, marked as a still.
    static func adoptStill(
        imageData: Data, originalName: String, label: String, store: ProjectStore, projectID: UUID
    ) async throws -> SourceAsset {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            try await StillVideoWriter.write(imageData: imageData, to: temp, label: label)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        var source = try await adopt(tempURL: temp, originalName: originalName, store: store, projectID: projectID)
        source.isStill = true
        return source
    }

    static func adopt(tempURL: URL, originalName: String?, store: ProjectStore, projectID: UUID) async throws
        -> SourceAsset
    {
        let name = try store.adoptMedia(at: tempURL, projectID: projectID)
        let stored = store.mediaDirectory(for: projectID).appendingPathComponent(name)
        do {
            return try await analyze(url: stored, fileName: name, originalFilename: originalName)
        } catch {
            try? FileManager.default.removeItem(at: stored)
            throw error
        }
    }
}

// MARK: - Photos

/// Turns a photo into a silent movie that holds the picture, so stills take the same
/// composition, trim, framing and export path as video. The movie runs `duration`, so a
/// photo clip can be stretched that long; it starts at `SourceAsset.stillClipDuration`.
enum StillVideoWriter {
    static let duration = MediaTime(seconds: 10)
    static let frameRate: Int32 = 30
    /// The longer side of the movie. Enough for a 1080×1920 export at any framing.
    static let maxDimension: CGFloat = 1920

    /// Writes `imageData` (HEIC, JPEG, PNG…) as a .mov at `url`, upright and at most `maxDimension`.
    static func write(imageData: Data, to url: URL, label: String) async throws {
        guard let image = UIImage(data: imageData), let upright = uprightImage(image) else {
            throw ImportError.unreadable(label)
        }
        let width = upright.width
        let height = upright.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ImportError.unreadable(label) }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else { throw ImportError.unreadable(label) }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { throw ImportError.unreadable(label) }
        draw(upright, into: buffer)

        // Every frame at the sequence rate, so trimming snaps to frames like any video.
        // Identical frames cost next to nothing once encoded.
        let frames = Int(duration.seconds * Double(frameRate))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: duration.cmTime)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ImportError.unreadable(label) }
    }

    /// The photo drawn the right way up, scaled to fit `maxDimension`, with even pixel sides.
    private static func uprightImage(_ image: UIImage) -> CGImage? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(pixels.width, pixels.height))
        let size = CGSize(
            width: max(2, (pixels.width * scale / 2).rounded() * 2),
            height: max(2, (pixels.height * scale / 2).rounded() * 2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
