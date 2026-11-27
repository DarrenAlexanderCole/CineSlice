@preconcurrency import AVFoundation
import CoreImage
import EditCore
import Photos

/// Copies takes out to the phone as well as into the bin, when the Record page's SAVE key is on:
/// video and photos to Photos, through their look (anything leaving the app carries it), and
/// sound to the app's Sounds folder, which the Files app shows under On My iPhone › CINE SLICE.
/// The bin's copy is untouched; these are extra copies.
enum DeviceSaver {
    enum SaveError: LocalizedError {
        case photosAccessDenied
        case couldNotRender

        var errorDescription: String? {
            switch self {
            case .photosAccessDenied: "CineSlice isn't allowed to add to Photos. Turn it on in Settings › CineSlice."
            case .couldNotRender: "The look couldn't be drawn onto the copy."
            }
        }
    }

    /// Asks once for leave to add to Photos; true when it's given.
    static func canAddToPhotos() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// The video to Photos, drawn through `look` first when it has one.
    static func saveVideo(_ url: URL, look: Look?) async throws {
        guard await canAddToPhotos() else { throw SaveError.photosAccessDenied }
        var file = url
        var rendered: URL?
        if let look {
            let out = try await render(url, through: look)
            file = out
            rendered = out
        }
        defer { if let rendered { try? FileManager.default.removeItem(at: rendered) } }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
        }
    }

    /// The photo to Photos, through `look` when it has one (as HEIC, keeping its orientation).
    static func savePhoto(_ data: Data, look: Look?) async throws {
        guard await canAddToPhotos() else { throw SaveError.photosAccessDenied }
        var output = data
        if let look, let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            let graded = LookLibrary.apply(look, to: image)
            let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            guard let heic = CIContext().heifRepresentation(of: graded, format: .RGBA8, colorSpace: space) else {
                throw SaveError.couldNotRender
            }
            output = heic
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: output, options: nil)
        }
    }

    /// The sound into the Sounds folder (visible in the Files app), named for the take.
    static func saveSound(_ url: URL, named name: String) throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        var destination = folder.appendingPathComponent(base).appendingPathExtension(url.pathExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
    }

    /// A copy of the movie with the look drawn on, sound and all, at full quality.
    private static func render(_ url: URL, through look: Look) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            request.finish(with: LookLibrary.apply(look, to: request.sourceImage), context: nil)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw SaveError.couldNotRender
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        session.videoComposition = composition
        if #available(iOS 18, *) {
            try await session.export(to: out, as: .mov)
        } else {
            session.outputURL = out
            session.outputFileType = .mov
            await session.export()
            if let error = session.error { throw error }
            guard session.status == .completed else { throw SaveError.couldNotRender }
        }
        return out
    }
}
