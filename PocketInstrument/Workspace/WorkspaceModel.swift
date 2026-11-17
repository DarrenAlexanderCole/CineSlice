import AVFoundation
import EditCore
import Observation
import PhotosUI
import SwiftUI

/// UI state for one open project. All mutations of `project` go through
/// `perform(_:)` (undoable commands); media work happens in CompositionBuilder,
/// MediaImporter and ExportService, never in views.
@MainActor
@Observable
final class WorkspaceModel {
    enum Mode: String, CaseIterable {
        case arrange, explore, mix

        /// User-facing name. The explore state is shown as "Trim".
        var title: String {
            switch self {
            case .arrange: "Arrange"
            case .explore: "Trim"
            case .mix: "Mix"
            }
        }
    }

    private(set) var project: Project
    private(set) var mode: Mode = .arrange
    var selectedClipID: UUID?
    /// Explore only: loops the clip's in/out range. Arrange and Mix use the project's loop region.
    var loopSelection = false { didSet { updateLoopRange() } }

    /// Peaks for the reference music, loaded from cache or analyzed in the background.
    private(set) var waveform: Waveform?

    /// In-progress trim while a handle is being dragged (committed on release as one undo step).
    var draftRange: MediaTimeRange?

    var importStatus: String?
    var alertMessage: String?
    private(set) var isRebuilding = false

    let engine = PlaybackEngine()
    let store: ProjectStore

    @ObservationIgnored private var undoStack = UndoStack()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    /// Audio track IDs in the loaded sequence item, for live level changes.
    @ObservationIgnored private var loadedTrackIDs: (clip: CMPersistentTrackID?, music: CMPersistentTrackID?)
    private(set) var undoName: String?
    private(set) var redoName: String?

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        self.selectedClipID = project.clips.first?.id
    }

    // MARK: Derived

    var sequenceMap: SequenceMap { SequenceMap(project: project) }
    var selectedClip: TimelineClip? { selectedClipID.flatMap { project.clip(id: $0) } }
    var selectedSource: SourceAsset? { selectedClip.flatMap { project.source(for: $0) } }

    func mediaURL(for source: SourceAsset) -> URL? {
        store.isMissing(source, projectID: project.id) ? nil : store.mediaURL(for: source, projectID: project.id)
    }

    func mediaURL(for clip: TimelineClip) -> URL? {
        project.source(for: clip).flatMap { mediaURL(for: $0) }
    }

    /// Current time in the active domain: composition time in Arrange, source time in Explore.
    var currentTime: MediaTime { MediaTime(engine.currentTime) }

    /// The clip under the playhead in Arrange.
    var clipUnderPlayhead: UUID? { sequenceMap.entry(at: currentTime)?.clipID }

    var musicURL: URL? { project.referenceAudio.flatMap { store.audioURL(for: $0, projectID: project.id) } }

    /// One frame at the export rate: the nudge step for music and loop edges.
    var sequenceFrame: MediaTime { MediaTime(value: 1, timescale: Int32(project.exportSettings.frameRate)) }

    /// The fine music nudge.
    static let tenMilliseconds = MediaTime(value: 10, timescale: 1000)

    // MARK: Lifecycle

    func open() {
        rebuildSequence(keepingTime: .zero)
        loadWaveform()
    }

    func close() {
        saveNow()
        engine.tearDown()
        rebuildTask?.cancel()
        waveformTask?.cancel()
    }

    // MARK: Commands / undo

    func perform(_ command: EditingCommand) {
        let previous = project
        do {
            try undoStack.perform(command, on: &project)
            didEdit(from: previous)
        } catch {
            alertMessage = "\(command.actionName) failed: \(error.localizedDescription)"
            Haptics.warning()
        }
    }

    func undo() {
        let previous = project
        guard undoStack.undo(&project) != nil else { return }
        didEdit(from: previous)
    }

    func redo() {
        let previous = project
        guard undoStack.redo(&project) != nil else { return }
        didEdit(from: previous)
    }

    private func didEdit(from previous: Project) {
        undoName = undoStack.undoActionName
        redoName = undoStack.redoActionName
        if let id = selectedClipID, project.clip(id: id) == nil {
            selectedClipID = project.clips.first?.id
        }
        if mode == .explore, selectedClip == nil { mode = .arrange }
        if previous.referenceAudio?.fileName != project.referenceAudio?.fileName { loadWaveform() }
        scheduleSave()
        if mode != .explore, Self.playbackShape(previous) == Self.playbackShape(project) {
            // Levels or loop only: adjust the live item instead of reloading it, so playback doesn't stutter.
            applyLevels()
            updateLoopRange()
        } else {
            refreshPlayback()
        }
    }

    /// The parts of a project that need the composition rebuilt when they change.
    private static func playbackShape(_ p: Project) -> Project {
        var shape = p
        shape.modifiedAt = .distantPast
        shape.name = ""
        for i in shape.clips.indices { shape.clips[i].volume = 1 }
        shape.referenceAudio?.volume = 1
        shape.loop = nil
        shape.exportSettings = .vertical1080  // preview always plays the full mix; the policy is export-only
        return shape
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do { try store.save(project) } catch { alertMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    // MARK: Playback wiring

    private func refreshPlayback() {
        switch mode {
        case .arrange, .mix:
            rebuildSequence(keepingTime: currentTime)
        case .explore:
            // Source item stays loaded; only the loop window may change.
            updateLoopRange()
        }
    }

    /// Rebuilds the sequence composition (debounced so rapid edits don't thrash the player).
    func rebuildSequence(keepingTime time: MediaTime, resume: Bool? = nil) {
        rebuildTask?.cancel()
        let snapshot = project
        let store = self.store
        isRebuilding = true
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if snapshot.clips.isEmpty {
                self.engine.load(nil, duration: .zero, at: .zero)
                self.isRebuilding = false
                return
            }
            do {
                // Preview always plays clips + music at the mix levels; the sound policy applies to export only.
                let built = try await CompositionBuilder.build(
                    project: snapshot,
                    renderSize: CGSize(width: snapshot.exportSettings.width, height: snapshot.exportSettings.height),
                    frameRate: Int32(snapshot.exportSettings.frameRate),
                    includeClipAudio: true,
                    includeMusic: true,
                    mediaURL: {
                        store.isMissing($0, projectID: snapshot.id)
                            ? nil : store.mediaURL(for: $0, projectID: snapshot.id)
                    },
                    musicURL: snapshot.referenceAudio.flatMap { store.audioURL(for: $0, projectID: snapshot.id) })
                guard !Task.isCancelled, self.mode != .explore else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                self.loadedTrackIDs = (built.clipAudioTrackID, built.musicTrackID)
                let target = CMTimeMinimum(time.cmTime, built.duration)
                self.engine.load(item, duration: built.duration, at: target, resume: resume)
                self.updateLoopRange()
            } catch {
                if !Task.isCancelled { self.alertMessage = error.localizedDescription }
            }
            self.isRebuilding = false
        }
    }

    private func updateLoopRange() {
        switch mode {
        case .arrange, .mix:
            engine.loopRange = activeLoop?.range.cmTimeRange
        case .explore:
            guard loopSelection, let clip = selectedClip else {
                engine.loopRange = nil
                return
            }
            engine.loopRange = (draftRange ?? clip.sourceRange).cmTimeRange
        }
    }

    /// Sets the player's levels; `clip` (for the selected clip) and `music` override the project's
    /// for live fader previews.
    func applyLevels(clip: Float? = nil, music: Float? = nil) {
        guard mode != .explore, let item = engine.player.currentItem else { return }
        item.audioMix = CompositionBuilder.audioMix(
            project: project, clipAudioTrackID: loadedTrackIDs.clip, musicTrackID: loadedTrackIDs.music,
            clipLevel: clip.flatMap { level in selectedClipID.map { (id: $0, volume: level) } }, musicLevel: music)
    }

    // MARK: Selection & modes

    func select(_ clipID: UUID) {
        selectedClipID = clipID
        Haptics.detent()
        if mode != .explore, let start = sequenceMap.compositionStart(of: clipID) {
            engine.seek(to: start.cmTime, precise: true)
        }
        updateLoopRange()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        Haptics.detent()
        switch newMode {
        case .explore:
            enterExplore()
        case .arrange, .mix:
            let fromExplore = mode == .explore
            mode = newMode
            draftRange = nil
            if fromExplore {
                let start = selectedClipID.flatMap { sequenceMap.compositionStart(of: $0) } ?? .zero
                rebuildSequence(keepingTime: start, resume: false)
            } else {
                updateLoopRange()
            }
        }
    }

    func enterExplore(_ clipID: UUID? = nil) {
        if let clipID { selectedClipID = clipID }
        guard let clip = selectedClip, let source = project.source(for: clip) else { return }
        guard let url = mediaURL(for: source) else {
            alertMessage = "This clip's media file is missing."
            return
        }
        rebuildTask?.cancel()
        mode = .explore
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        engine.load(item, duration: source.duration.cmTime, at: clip.sourceRange.start.cmTime, resume: false)
        updateLoopRange()
    }

    // MARK: Loop region (composition time)

    /// The loop region fitted to the current sequence, if it's switched on.
    var activeLoop: LoopRange? {
        guard let loop = project.loop, loop.isEnabled else { return nil }
        return loop.clamped(toSequence: project.duration)
    }

    /// Switches the loop on or off. The first time, it starts as the selected clip (or the whole sequence).
    func toggleLoop() {
        if var loop = project.loop {
            loop.isEnabled.toggle()
            perform(SetLoopCommand(loop: loop))
        } else {
            let range =
                selectedClipID.flatMap { sequenceMap.entry(for: $0)?.compositionRange }
                ?? MediaTimeRange(start: .zero, duration: project.duration)
            perform(SetLoopCommand(loop: LoopRange(range: range)))
        }
        Haptics.tap()
    }

    func setLoopRange(_ range: MediaTimeRange) {
        perform(SetLoopCommand(loop: LoopRange(range: range, isEnabled: true)))
    }

    /// Loops the selected clip's place in the sequence.
    func loopSelectedClip() {
        guard let id = selectedClipID, let range = sequenceMap.entry(for: id)?.compositionRange else { return }
        setLoopRange(range)
        Haptics.tap()
    }

    func loopWholeSequence() {
        setLoopRange(MediaTimeRange(start: .zero, duration: project.duration))
        Haptics.tap()
    }

    /// Loop In / Loop Out at the playhead, keeping the other edge when it still makes sense.
    func setLoopIn() {
        guard let loop = LoopRange.settingStart(currentTime, of: activeLoop, sequenceDuration: project.duration)
        else { return }
        perform(SetLoopCommand(loop: loop))
        Haptics.press()
    }

    func setLoopOut() {
        guard let loop = LoopRange.settingEnd(currentTime, of: activeLoop, sequenceDuration: project.duration)
        else { return }
        perform(SetLoopCommand(loop: loop))
        Haptics.press()
    }

    // MARK: Arrange edits

    func addSources(_ sources: [SourceAsset]) {
        guard !sources.isEmpty else { return }
        let command = AddClipsCommand(sources: sources)
        perform(command)
        selectedClipID = command.clipIDs.first
    }

    func move(_ clipID: UUID, to index: Int) { perform(MoveClipCommand(clipID: clipID, toIndex: index)) }
    func remove(_ clipID: UUID) { perform(RemoveClipCommand(clipID: clipID)) }
    func duplicate(_ clipID: UUID) {
        let command = DuplicateClipCommand(clipID: clipID)
        perform(command)
        selectedClipID = command.newClipID
    }
    func toggleFraming(_ clipID: UUID) {
        guard let clip = project.clip(id: clipID) else { return }
        perform(SetFramingCommand(clipID: clipID, framing: clip.framing == .fill ? .fit : .fill))
    }
    func rename(_ name: String) { perform(RenameProjectCommand(name: name)) }
    func setSoundPolicy(_ policy: SoundPolicy) {
        var settings = project.exportSettings
        settings.soundPolicy = policy
        perform(SetExportSettingsCommand(settings: settings))
    }

    // MARK: Mix edits

    func setClipVolume(_ volume: Float) {
        guard let id = selectedClipID else { return }
        perform(SetClipVolumeCommand(clipID: id, volume: volume))
    }
    func setMusicVolume(_ volume: Float) { perform(SetMusicVolumeCommand(volume: volume)) }
    func setMusicOffset(_ offset: MediaTime) { perform(SetMusicOffsetCommand(offset: offset)) }

    /// Slides the music later (positive) or earlier (negative) by `step`.
    func nudgeMusic(by step: MediaTime) {
        guard let music = project.referenceAudio else { return }
        setMusicOffset(music.offset + step)
        Haptics.detent()
    }

    func removeMusic() { perform(SetReferenceAudioCommand(track: nil)) }

    func importMusicFile(_ url: URL) async {
        importStatus = "Importing music…"
        do {
            finishMusicImport(try await MediaImporter.importAudioFile(url, store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    func importMusic(fromVideo item: PhotosPickerItem) async {
        importStatus = "Extracting sound…"
        do {
            finishMusicImport(try await MediaImporter.importAudio(fromVideo: item, store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    func addDemoClickTrack() async {
        importStatus = "Generating click track…"
        do {
            finishMusicImport(try await DemoMediaGenerator.makeClickTrack(store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    private func finishMusicImport(_ track: AudioTrack) {
        importStatus = nil
        perform(SetReferenceAudioCommand(track: track))
        Haptics.success()
    }

    private func finishMusicImport(_ error: Error) {
        importStatus = nil
        alertMessage = error.localizedDescription
        Haptics.warning()
    }

    private func loadWaveform() {
        waveformTask?.cancel()
        waveform = nil
        guard let track = project.referenceAudio, let url = musicURL else { return }
        let cacheURL = store.waveformCacheURL(for: track, projectID: project.id)
        waveformTask = Task { [weak self] in
            let result = try? await WaveformAnalyzer.waveform(for: url, cacheURL: cacheURL)
            guard !Task.isCancelled, let self, self.project.referenceAudio?.fileName == track.fileName else { return }
            self.waveform = result
        }
    }

    // MARK: Explore edits (source time)

    func markIn() {
        guard let clip = selectedClip else { return }
        let t = currentTime
        perform(
            TrimClipCommand(
                clipID: clip.id,
                sourceRange: MediaTimeRange(start: t, end: max(clip.sourceRange.end, t + minimumClipDuration))))
        Haptics.press()
    }

    func markOut() {
        guard let clip = selectedClip else { return }
        let t = currentTime
        perform(
            TrimClipCommand(
                clipID: clip.id,
                sourceRange: MediaTimeRange(start: min(clip.sourceRange.start, t - minimumClipDuration), end: t)))
        Haptics.press()
    }

    func updateDraft(_ range: MediaTimeRange, previewAt time: MediaTime) {
        guard let source = selectedSource else { return }
        draftRange = TrimClipCommand.clamp(range, toSourceDuration: source.duration)
        engine.seek(to: time.cmTime, precise: false)
        updateLoopRange()
    }

    func commitDraft() {
        guard let clip = selectedClip, let range = draftRange else { return }
        draftRange = nil
        perform(TrimClipCommand(clipID: clip.id, sourceRange: range))
    }

    func scrub(to time: MediaTime, precise: Bool) {
        engine.seek(to: time.cmTime, precise: precise)
    }

    func step(_ frames: Int) {
        engine.step(frames: frames)
        Haptics.detent()
    }

    // MARK: Import

    func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let (sources, errors) = await MediaImporter.importPhotos(items, store: store, projectID: project.id) {
            [weak self] i, n in
            self?.importStatus = "Importing \(i) of \(n)…"
        }
        finishImport(sources, errors)
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let (sources, errors) = await MediaImporter.importFiles(urls, store: store, projectID: project.id) {
            [weak self] i, n in
            self?.importStatus = "Importing \(i) of \(n)…"
        }
        finishImport(sources, errors)
    }

    func addDemoClips() async {
        importStatus = "Generating demo clips…"
        do {
            let sources = try await DemoMediaGenerator.makeDemoSources(store: store, projectID: project.id)
            finishImport(sources, [])
        } catch {
            finishImport([], [error])
        }
    }

    private func finishImport(_ sources: [SourceAsset], _ errors: [Error]) {
        importStatus = nil
        addSources(sources)
        if !errors.isEmpty {
            alertMessage = errors.map { $0.localizedDescription }.joined(separator: "\n")
        } else if !sources.isEmpty {
            Haptics.success()
        }
    }
}
