import EditCore
import Observation
import SwiftUI

/// LIGHTBOX's own state: what part of the timeline it shows and the peaks of each clip source's
/// sound for its film strips. View state only, never saved; it lives with the workspace so turning
/// the phone upright and back finds the table as it was left.
@MainActor
@Observable
final class LightboxState {
    var viewport = TimelineViewport()
    /// The lanes' width in points, for keeping the playhead on screen.
    var lanesWidth: Double = 0
    /// Each section's height in points, for clamping scroll and resizing about the middle lane.
    var videoHeight: Double = 0
    var audioHeight: Double = 0
    /// The table has been fitted to the project once (the first time it's shown).
    var hasFitted = false
    var isToolsOpen = false
    /// Which lanes the scroll and size rollers work: video (true) or audio.
    var rollersOnVideo = true
    /// The monitor beside the table (true), or the table across the whole width.
    var showsMonitor = true

    /// Peaks of each source's own sound, by source ID. Silent sources never get one.
    private(set) var waveforms: [UUID: Waveform] = [:]
    /// Peaks of each sound file on the sound lanes, by file name.
    private(set) var soundWaveforms: [String: Waveform] = [:]
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var queued: Set<String> = []

    private enum Peaks {
        case source(UUID)
        case sound(String)
    }

    /// Reads (or analyzes and caches) the sound of every source that has some, and of every
    /// sound file, that isn't loaded yet, one at a time in the background.
    func loadWaveforms(_ model: WorkspaceModel) {
        let store = model.store
        let projectID = model.project.id
        var jobs: [(key: String, peaks: Peaks, url: URL, cache: URL)] = []
        for source in model.project.sources where source.hasAudio && waveforms[source.id] == nil {
            guard !queued.contains(source.id.uuidString), let url = model.mediaURL(for: source) else { continue }
            jobs.append(
                (
                    source.id.uuidString, .source(source.id), url,
                    store.waveformCacheURL(for: source, projectID: projectID)
                ))
        }
        for clip in model.project.soundTracks.flatMap(\.clips) where soundWaveforms[clip.fileName] == nil {
            guard !queued.contains(clip.fileName), !jobs.contains(where: { $0.key == clip.fileName }),
                let url = store.soundURL(for: clip, projectID: projectID)
            else { continue }
            jobs.append(
                (clip.fileName, .sound(clip.fileName), url, store.waveformCacheURL(for: clip, projectID: projectID)))
        }
        guard !jobs.isEmpty else { return }
        queued.formUnion(jobs.map(\.key))
        let previous = waveformTask
        waveformTask = Task { [weak self] in
            await previous?.value
            for job in jobs {
                guard !Task.isCancelled else { return }
                let waveform = try? await WaveformAnalyzer.waveform(for: job.url, cacheURL: job.cache)
                guard let self, !Task.isCancelled else { return }
                guard let waveform else { continue }
                switch job.peaks {
                case .source(let id): self.waveforms[id] = waveform
                case .sound(let name): self.soundWaveforms[name] = waveform
                }
            }
        }
    }

    func cancel() {
        waveformTask?.cancel()
        waveformTask = nil
        queued.removeAll()
    }
}
