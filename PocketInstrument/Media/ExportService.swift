import AVFoundation
import EditCore
import Photos

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
/// Output: H.264 MP4 at the project's export size (default 1080×1920, 30 fps),
/// with the sound chosen by `Project.exportSoundPolicy`.
enum ExportService {
    static func export(
        project: Project, store: ProjectStore,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> ExportResult {
        let settings = project.exportSettings
        let policy = project.exportSoundPolicy
        let built = try await CompositionBuilder.build(
            project: project,
            renderSize: CGSize(width: settings.width, height: settings.height),
            frameRate: Int32(settings.frameRate),
            includeClipAudio: policy.includesClipAudio,
            includeMusic: policy.includesMusic,
            mediaURL: { source in
                store.isMissing(source, projectID: project.id)
                    ? nil : store.mediaURL(for: source, projectID: project.id)
            },
            musicURL: project.referenceAudio.flatMap { store.audioURL(for: $0, projectID: project.id) })

        guard
            let session = AVAssetExportSession(
                asset: built.composition,
                presetName: AVAssetExportPresetHighestQuality)
        else {
            throw ExportError.cannotCreateSession
        }

        let folder = store.exportsDirectory(for: project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = project.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let stamp = Int(Date().timeIntervalSince1970)
        let url = folder.appendingPathComponent("\(safeName.isEmpty ? "Export" : safeName)-\(stamp).mp4")
        try? FileManager.default.removeItem(at: url)

        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = built.videoComposition
        // A silent export has no audio tracks at all, so there's no mix to apply.
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true

        let box = ExportSessionBox(session: session)

        // Poll progress while the export runs.
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poller.cancel() }

        try await run(session)

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

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photosAccessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
