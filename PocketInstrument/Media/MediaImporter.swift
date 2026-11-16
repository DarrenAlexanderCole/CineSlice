import AVFoundation
import CoreTransferable
import EditCore
import PhotosUI
import SwiftUI
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

    /// Photos picker → project media. Returns the sources that imported and the errors for those that didn't.
    static func importPhotos(
        _ items: [PhotosPickerItem], store: ProjectStore, projectID: UUID,
        progress: @MainActor (Int, Int) -> Void
    ) async -> ([SourceAsset], [Error]) {
        var sources: [SourceAsset] = []
        var errors: [Error] = []
        for (i, item) in items.enumerated() {
            await progress(i + 1, items.count)
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ImportError.unreadable("Item \(i + 1)")
                }
                sources.append(
                    try await adopt(tempURL: movie.url, originalName: nil, store: store, projectID: projectID))
            } catch {
                errors.append(error)
            }
        }
        return (sources, errors)
    }

    /// Files app → project media (security-scoped URLs are copied, never moved).
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
